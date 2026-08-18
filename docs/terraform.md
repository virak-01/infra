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
  bootstrap/       S3 state bucket + lock table. Local state. Run once.
  infra/           THE EKS STACK — network, registry, dns, cluster, IRSA
  infra-kubeadm/   THE KUBEADM STACK — 1 control plane + N workers on EC2
  platform/        the controllers, via Helm. Separate apply (see step 4)
  modules/
    network/       vpc · subnets · igw · nat · routes · THE DISCOVERY TAGS · ALB SG
    registry/      3 ECR repos · immutable tags · lifecycle policy   } shared
    dns/           zone · ACM cert · validation records              } by both
    cluster/       EKS · managed node group · OIDC · addons          ] EKS
    iam-irsa/      alb-controller, external-dns, autoscaler roles    ] only
    ec2/           control plane + workers · cloud-init user-data    ] kubeadm
    security-group/ the ports kubeadm actually needs                 ] only
    iam-node/      node instance roles, scoped to the SSM join path  ]
script/
  bootstrap/           control-plane.sh · worker.sh · install-containerd.sh
script/
  fetch-policies.sh    pulls the pinned upstream ALB controller IAM policy
  sync-manifests.sh    carries outputs into k8s/ (--check for CI)
k8s/           the manifests this infrastructure exists to run
```

## Two stacks: EKS or kubeadm

`terraform/` holds two root modules that build the same platform different ways. They
share the `network`, `registry` and `dns` modules and keep **separate state**, so both
can exist in one account without fighting. Pick one per cluster — running both means
two clusters and two bills.

| | [`infra/`](../terraform/infra) | [`infra-kubeadm/`](../terraform/infra-kubeadm) |
|---|---|---|
| Control plane | AWS runs it | you run it, on an EC2 instance |
| Compute resources | 2 | 6 (1 + 5 workers) |
| Node join | automatic, via the EKS API | `kubeadm join` with an SSM-delivered token |
| Controller permissions | IRSA, per ServiceAccount | node instance role |
| ECR pull credentials | node role — `registry-ecr` unnecessary | the `registry-ecr` CronJob is required |
| Control-plane cost | ~$73/month | none |
| Matches the live cluster | no — a migration target | yes |

### How six machines install Kubernetes simultaneously

This is the kubeadm stack's central problem, and it is worth understanding before the
first apply. All six instances boot in parallel, so the workers reach their join step
**minutes before** the control plane has finished `kubeadm init`. No Terraform
construct fixes that — `depends_on` orders API calls, not software inside an instance.

```
   Terraform                Control plane                 Workers × 5
       │                          │                             │
       │ creates SSM parameter    │                             │
       │ value = "PENDING"        │                             │
       ├─────────────────────────►│                             │
       │ RunInstances × 6, parallel                             │
       ├──────────────┬──────────►│                             │
       │              └──────────────────────────────────────►  │
  t+2m │                          │ containerd, kubeadm         │ containerd, kubeadm
  t+3m │                          │ kubeadm init                │ poll SSM ─┐
  t+4m │                          │ apply Calico                │  every 15s │ up to
  t+5m │                          │ token create --ttl 1h       │  ◄─────────┘ 20 min
       │                          │ ssm put-parameter ──────────┼──►
  t+6m │                          │◄──── kubeadm join × 5 ──────┤
```

Each worker polls with its own independent deadline, so five do not queue behind each
other. Five concurrent joins against one API server are fine: each performs its own
TLS bootstrap and CSR, which is what a bootstrap token exists for.

**The token is never in git, in state, or in user-data.** It is minted on the control
plane *after* the cluster exists and published to SSM as a SecureString. The
control-plane role may write that one parameter and cannot read it back; the worker
role may read it and cannot write. See [`modules/iam-node`](../terraform/modules/iam-node/main.tf).

### Running the kubeadm stack

```sh
cd terraform/infra-kubeadm
terraform init
terraform apply                                  # ~3 min for AWS, ~6 more inside the nodes
```

`terraform apply` returning does **not** mean the cluster is ready — cloud-init is
still running. Watch it:

```sh
# with key_name set:
ssh ubuntu@$(terraform output -raw control_plane_public_ip) 'sudo tail -f /var/log/k8s-bootstrap.log'

# with key_name = null (the default) — no key, no open port 22:
aws ssm start-session --target "$(terraform output -raw control_plane_instance_id)"
#   then, in the session:  sudo tail -f /var/log/k8s-bootstrap.log
kubectl get nodes -w        # expect 1 control-plane + 5 workers
```

If a worker misses its window, the token has usually expired by the time anyone looks.
Mint a fresh one and join — idempotent, and it skips nodes that already joined:

```sh
./script/bootstrap/worker.sh          # on the node itself, or:
kubectl get nodes                     # confirm which are missing
```

Changing the worker count is one line in `terraform.tfvars`; the security groups need
no edit because they reference each other **by security group, not by IP address**, so
new nodes are covered the moment they launch.

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
./script/fetch-policies.sh
```

### Credentials

Terraform's AWS provider uses the standard credential chain, so anything that already
works for the `aws` CLI works here. If you keep them in `.env`:

```sh
cp .env.example .env            # then fill it in
./script/with-aws-env.sh --whoami
```

**Nothing reads `.env` automatically** — not Terraform, not the `aws` CLI, not bash. A
correctly-filled `.env` has no effect until something exports it, which is what
[`script/with-aws-env.sh`](../script/with-aws-env.sh) does:

```sh
./script/with-aws-env.sh terraform -chdir=terraform/infra plan
```

It scopes the credentials to that one process rather than leaving them in your shell
for the rest of the session. The equivalent by hand is `set -a; . ./.env; set +a`.

> **The variable names are not arbitrary.** The SDK reads `AWS_ACCESS_KEY_ID` and
> `AWS_SECRET_ACCESS_KEY` and nothing else — `AWS_KEY` / `AWS_SECRET` are silently
> ignored, so Terraform falls through to `~/.aws/credentials` and either uses the
> wrong account or fails with "no valid credential sources found". A `.env` with the
> wrong names is indistinguishable from no `.env` at all.
>
> A named profile (`AWS_PROFILE`) is preferable to static keys, and is the only option
> that works with SSO. See [`.env.example`](../.env.example).

`fetch-policies.sh` downloads the AWS-published load balancer controller IAM
policy. It is not inline HCL because it is ~180 statements with specific conditions,
revised per controller release; a hand-copied version fails at ALB-creation time
with an `AccessDenied` naming an action you did not know the controller needed.

### 1 — state backend

```sh
cd terraform/bootstrap
terraform init
terraform apply                 # no -var: the name derives from your account
```

Then point every backend at it:

```sh
cd ../..
./script/tf-backend.sh --write
```

The backend blocks carry a literal bucket and region, because a backend block accepts
no variables at all — Terraform reads it before evaluating anything else. `-backend-config`
overrides either value per command. Locking uses `use_lockfile = true` (an object in
the same bucket), which replaced the DynamoDB table Terraform deprecated in 1.11.

Full command sequence and every error this produces: [running-terraform.md](running-terraform.md).

### 2 — the AWS stack

```sh
cd ../infra
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
