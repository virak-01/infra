# Terraform

The AWS side of this repository: the VPC, the EKS cluster, the registries, the
certificate, and the four in-cluster controllers the manifests in [`k8s/`](../k8s)
cannot work without.

Manifests and infrastructure live in one repository on purpose — the values they share
(registry host, certificate ARN, VPC CIDR) can then be checked against each other by
[`script/sync-manifests.sh`](../script/sync-manifests.sh) in CI, rather than drifting
between two checkouts.

**Terraform stops at the load balancer.** See [Ownership](#the-boundary) below.

**It stops at the load balancer, on purpose.** The AWS Load Balancer Controller
builds the ALB from the Ingress object and reconciles it continuously. Nothing here
writes `aws_lb`, `aws_lb_listener`, `aws_lb_target_group`, or the target-group
attachments — two owners on one resource means Terraform destroys what the
controller built, the controller rebuilds it, and no `terraform plan` is ever
empty. Terraform's job at the edge is to create and **tag** the network; the tags
are how the controller discovers where to put the ALB.

```
terraform/
  bootstrap/   S3 state bucket + lock table. Local state. Run once.
  infra/       THE STACK — network, registry, dns, cluster, IRSA roles
  platform/    the controllers, via Helm. Separate apply (see step 4)
  modules/
    network/   vpc · subnets · igw · nat · routes · THE DISCOVERY TAGS · ALB SG
    registry/  3 ECR repos · immutable tags · lifecycle policy
    dns/       zone · ACM cert · validation records  (no ALIAS — see below)
    cluster/   EKS · managed node group · OIDC provider · addons
    iam-irsa/  per-controller roles: alb-controller, external-dns, autoscaler
script/
  fetch-policies.sh    pulls the pinned upstream ALB controller IAM policy
  sync-manifests.sh    carries outputs into k8s/ (--check for CI)
k8s/           the manifests this infrastructure exists to run
```

## Why there is no `envs/uat` and `envs/prod`

UAT and prod **share one cluster** and are separated by namespace — that is the
manifests repo's design, where `ENV` names both the overlay directory and the
namespace. So there is no per-environment AWS infrastructure: both pull from the
same ECR repositories with different tags, sit behind the same ALB, and share one
wildcard certificate.

Two root modules would create two VPCs and two clusters. That is a more expensive,
arguably more correct platform — but not the one the manifests describe. Environment
separation is enforced in Kubernetes: namespaces, NetworkPolicies, and separate
Argo CD Applications.

## Decisions already made

| | Chosen | Why |
|---|---|---|
| Cluster | **EKS + managed node group** | The kubeadm equivalent is five resources plus a manual `kubeadm token create`, two of which hold values Terraform cannot own. It also deletes the control-plane-pinned Cluster Autoscaler (which can never schedule on EKS) and the ECR pull-secret CronJob. |
| DNS records | **external-dns, in-cluster** | An ALIAS needs the ALB hostname, which needs `kubectl apply`, which runs after Terraform. One apply instead of two, and DNS follows a host change in an overlay automatically. |
| Node placement | **private subnets** | Pod IPs come from these ranges under the VPC CNI, so subnet size caps cluster pod capacity — hence /20s. |
| State | **S3 + DynamoDB** | Terraform 1.10+ can drop the table for `use_lockfile = true`; see `infra/backend.tf`. |

## Running it

Roughly 25 minutes end to end, most of it EKS creating the control plane.

### 0 — prerequisites

```sh
terraform -version      # >= 1.5
aws sts get-caller-identity
./script/fetch-policies.sh
```

`fetch-policies.sh` downloads the AWS-published load balancer controller IAM
policy. It is not inline HCL because it is ~180 statements with specific conditions,
revised per controller release; a hand-copied version fails at ALB-creation time
with an `AccessDenied` naming an action you did not know the controller needed.

### 1 — state backend

```sh
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=terraform-state-$(aws sts get-caller-identity --query Account --output text)"
terraform output backend_block      # paste into ../infra/backend.tf and ../platform/backend.tf
```

Local state here, and that is deliberate: a stack cannot hold the bucket its own
state lives in.

### 2 — the AWS stack

```sh
cd ../infra
cp terraform.tfvars.example terraform.tfvars    # edit: domain, CIDR, node sizes
terraform init
terraform plan
terraform apply
```

If `create_zone = true`, point your registrar at the `zone_name_servers` output
**now** — ACM validation cannot complete until the zone resolves, and the apply
waits up to 20 minutes for it.

### 3 — cluster access

```sh
aws eks update-kubeconfig --region us-east-1 --name bubernestes
kubectl get nodes                  # two Ready nodes
```

### 4 — the controllers

```sh
cd ../platform
cp terraform.tfvars.example terraform.tfvars    # edit: state_bucket, domain_filter
terraform init
terraform apply
```

**A separate root module, not tidiness.** The helm and kubernetes providers need
cluster credentials to build a plan. In one root module those are attributes of a
cluster that does not exist during the first plan, so the provider is configured
from unknown values and Terraform fails before applying anything — the familiar
`cannot connect to localhost:80`. Splitting the apply removes the problem rather
than papering over it with `-target`, which leaves state half-applied.

```sh
kubectl -n kube-system get deploy   # 4 controllers Available
```

### 5 — hand the values to the manifests

```sh
terraform -chdir=terraform/infra output -json kustomize_values
./script/sync-manifests.sh --check     # what disagrees, exit 1 if anything does
./script/sync-manifests.sh --write     # rewrite the overlays in place
```

Kustomize cannot read Terraform state, so these values live in both halves of the
repository:

| File in k8s/ | Value |
|---|---|
| `k8s/overlays/*/kustomization.yaml` | ECR registry host |
| `k8s/components/ingress-alb/` | ACM certificate ARN |
| `k8s/components/ingress-alb/` | VPC CIDR, in the NetworkPolicy `ipBlock` |

Run `--check` in CI. Otherwise the drift is silent: a value
changes in AWS, the manifests keep the old one, and the first symptom is an
unhealthy target group.

### 6 — deploy the workloads

```sh
cd "$(git rev-parse --show-toplevel)"
make deploy rollout ENV=uat
```

## Changes needed in k8s/

This stack is EKS, and four things in `k8s/` still assume the kubeadm cluster. None of them break the apply — they break the deploy.

1. **Drop `registry-ecr` from both overlays.** The node role carries
   `AmazonEC2ContainerRegistryReadOnly`, so the pull-secret CronJob and its
   unrotated IAM access key are both unnecessary. Use
   `components/ingress-alb` alone.
2. **Do not run `make cluster`.** `k8s/cluster/aws/cluster-autoscaler` pins itself
   to a control-plane node, which does not exist in an EKS cluster — the pod stays
   Pending forever. `platform/` installs the autoscaler via Helm with
   auto-discovery instead.
3. **Add the ALB security-group annotation** to the Ingress:
   `alb.ingress.kubernetes.io/security-groups: <alb_security_group_id>`. Without
   it the controller creates its own group, and the Terraform-owned node rule
   admits nothing.
4. **Consider `target-type: ip`.** `instance` exists because Calico pod IPs are not
   VPC-routable. Under the VPC CNI they are, so `ip` removes a hop and lets the
   Services go back to ClusterIP — deleting the NodePort override from
   `components/ingress-alb`.

## What this costs

| | Monthly |
|---|---|
| EKS control plane | ~$73 |
| 2 × t3.medium on-demand | ~$60 |
| NAT gateway (`single_nat_gateway = true`) | ~$32 + data |
| ALB | ~$16 + LCUs |
| ECR, Route 53, ACM, S3 state | a few dollars |

Roughly **$185/month** at the floor. `terraform destroy` in `platform/` then
`infra/` removes all of it — in that order, because the ALB is owned by the Ingress
and deleting the cluster first orphans the load balancer, its target groups, and its
security group, which keep billing.

```sh
kubectl delete -k k8s/overlays/uat    # removes the ALB first
kubectl delete -k k8s/overlays/prod
terraform -chdir=terraform/platform destroy
terraform -chdir=terraform/infra destroy
```

## Known gaps

- **The ALB controller policy is fetched, not committed.** `fetch-policies.sh` must
  run before the first plan on a fresh clone. A missing file fails the plan
  immediately, which is the right failure, but it is a manual step.
- **`external-dns` records are outside Terraform state.** `terraform destroy` leaves
  them; `policy=sync` means external-dns removes its own when the Ingress goes, so
  delete the manifests before the cluster.
- **No etcd concern, but no cluster backup either.** EKS manages etcd. Nothing here
  backs up the Kubernetes objects themselves — Argo CD and git are the recovery
  path, which works only for what is committed.
- **Not applied or validated.** `terraform` is not installed on this machine, so
  this code has been checked by cross-referencing module inputs and outputs, not by
  `terraform validate`. Run `terraform fmt -recursive && terraform validate` in each
  root module before the first apply.
