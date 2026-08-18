# First run, on a brand new AWS account

Nothing exists yet: no VPC, no cluster, no registry, no state bucket. This is the
complete path from an empty account to the applications serving traffic.

**Terraform creates almost all of it.** An earlier version of this document walked
through `aws ecr create-repository`, `eksctl create cluster`, `aws iam create-policy`
and subnet tagging by hand. Do not do that now — [`terraform/`](../terraform) owns every
one of those resources, and creating them first produces name conflicts on the first
apply (`AWSLoadBalancerControllerIAMPolicy` already exists, repositories already exist)
and an account half of which Terraform cannot manage.

Six phases, roughly **40 minutes**, most of it waiting on EKS.

---

## Decide first: which stack

Both exist and build the same platform. Pick one — running both means two clusters and
two bills.

| | [`terraform/infra`](../terraform/infra) — **EKS** | [`terraform/infra-kubeadm`](../terraform/infra-kubeadm) |
|---|---|---|
| Control plane | AWS runs it | you run it, on EC2 |
| Compute | 2 resources | 6 (1 control plane + 5 workers) |
| Nodes join | automatically | `kubeadm join`, token via SSM |
| Controller permissions | IRSA, per ServiceAccount | node instance role |
| ECR pull credentials | node role — `registry-ecr` unnecessary | the `registry-ecr` CronJob is required |
| Control-plane cost | ~$73/month | none |

**On a new account, take EKS.** It is fewer moving parts on the day you have the least
context, and it removes the two failure modes that cost the most time: the join-token
dance and a single control plane with no backup. The kubeadm path is documented in
[terraform.md](terraform.md#two-stacks-eks-or-kubeadm), and everything below applies to
it with `infra` swapped for `infra-kubeadm`.

---

## Phase 0 — Your machine

```sh
terraform -version            # >= 1.5
aws --version                 # v2
kubectl version --client      # >= 1.28
```

Credentials. **Confirm the account before anything writes to it** — every command below
acts on whatever this prints:

```sh
cp .env.example .env          # then edit it
./script/with-aws-env.sh --whoami
```

`.env` is gitignored. Nothing reads it automatically, so `with-aws-env.sh` loads it for
one command rather than leaving credentials in your shell — see
[terraform.md](terraform.md#credentials).

Fetch the load balancer controller's IAM policy. It is upstream's, pinned, and
gitignored, so a fresh clone does not have it — and Terraform cannot even build its
graph without it:

```sh
./script/fetch-policies.sh
```

---

## Phase 1 — Remote state

The backend must exist before the first `terraform init`. This runs with **local**
state, deliberately: a stack cannot hold the bucket its own state lives in.

```sh
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=k8s-tfstate-$(aws sts get-caller-identity --query Account --output text)"
terraform output -raw env_lines
```

That prints two lines. Put them in `.env`:

```
TF_STATE_BUCKET=k8s-tfstate-123456789012
TF_CLI_ARGS_init=-backend-config=bucket=k8s-tfstate-123456789012
```

Nothing gets pasted into `backend.tf`. The backend blocks already carry everything that
can be literal; `region` comes from `AWS_REGION` and `bucket` from `TF_CLI_ARGS_init`,
because a backend block accepts no variables at all.

Run once per account, never again.

---

## Phase 2 — The infrastructure

```sh
cd ../infra
cp terraform.tfvars.example terraform.tfvars
```

Edit three things:

| Variable | Why |
|---|---|
| `domain_name` | `null` skips DNS and TLS entirely — fine for a first run. If you set it, see the note below. |
| `public_access_cidrs` | narrow it. The default leaves the Kubernetes API endpoint reachable from the internet — authenticated, but reachable. |
| `cluster_name` | anything; it prefixes every resource. |

```sh
./script/with-aws-env.sh terraform init
./script/with-aws-env.sh terraform plan       # read it
./script/with-aws-env.sh terraform apply
```

**15–20 minutes**, nearly all of it EKS building the control plane.

> **If you set `domain_name` with `create_zone = true`**, point your registrar at the
> `zone_name_servers` output *now*. ACM validation cannot complete until the zone
> resolves, and the apply waits up to 20 minutes for it before failing.

---

## Phase 3 — Cluster access

```sh
./script/with-aws-env.sh terraform output -raw kubeconfig_command    # copy it
aws eks update-kubeconfig --region us-east-1 --name <cluster-name>

kubectl get nodes                   # two Ready nodes
```

---

## Phase 4 — The controllers

A separate apply, and not for tidiness: the helm and kubernetes providers need cluster
credentials to build a plan, and in one root module those are attributes of a cluster
that does not exist during the first plan.

```sh
cd ../platform
cp terraform.tfvars.example terraform.tfvars    # set state_bucket and domain_filter
./script/with-aws-env.sh terraform init
./script/with-aws-env.sh terraform apply

kubectl -n kube-system get deploy    # 4 controllers Available
```

This installs the AWS Load Balancer Controller (without it the Ingress is inert — no
address, no routing, no error anywhere), external-dns, metrics-server (without it every
HPA reports `<unknown>` and never scales), and the Cluster Autoscaler.

> `domain_filter` is not optional in practice. external-dns runs with `policy=sync`,
> which **deletes** records it believes are orphaned; an empty filter makes every hosted
> zone in the account eligible.

---

## Phase 5 — Hand the values to the manifests

Kustomize cannot read Terraform state, so a few values live in both halves.

```sh
cd ../..
./script/sync-manifests.sh --check     # what disagrees
./script/sync-manifests.sh --write     # rewrite the overlays
git diff                               # review before committing
```

Three manifest changes this stack needs, which the script deliberately does not make
for you:

1. **Drop `registry-ecr` from both overlays.** The node role carries
   `AmazonEC2ContainerRegistryReadOnly`, so the pull-secret CronJob and its unrotated
   IAM key are unnecessary on EKS. Name `components/ingress-alb` alone.
2. **Never run `make cluster`.** `k8s/cluster/aws/cluster-autoscaler` pins itself to a
   control-plane node, which does not exist on EKS — the pod stays Pending forever with
   no event naming the cause. Phase 4 installed the autoscaler properly.
3. **Add the ALB security-group annotation** to the Ingress, using the
   `alb_security_group_id` output. Without it the controller creates its own group and
   the Terraform-owned node rule admits nothing.

---

## Phase 6 — Push images, then deploy

**The ECR repositories are empty.** Terraform creates them; it does not fill them. This
repo deploys images and does not build them, so `make deploy` sits in
`ImagePullBackOff` until something has pushed:

```sh
aws ecr describe-images --repository-name website \
  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[].imageTags' --output text
```

Pin real tags in `k8s/overlays/uat/kustomization.yaml`, then:

```sh
make deploy  ENV=uat
make rollout ENV=uat
```

Add `make app-config ENV=uat` if the overlay has an `app-config.env` — it is gitignored,
so copy it from the `.example` first.

---

## Verify

```sh
kubectl get nodes
kubectl get pods -A
kubectl get ingress -A                 # ADDRESS populated
kubectl top nodes                      # metrics-server working
kubectl get hpa -A                     # TARGETS not <unknown>

ALB=http://$(kubectl -n uat get ingress company-web \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for p in / /api /api/auth /api/health; do
  printf '%-16s ' "$p"; curl -s -m 10 -o /dev/null -w '%{http_code}\n' "$ALB$p"
done
```

---

## Checklist

- [ ] `./script/with-aws-env.sh --whoami` shows the new account
- [ ] `./script/fetch-policies.sh` has run
- [ ] state bucket created; both `TF_*` lines in `.env`
- [ ] `terraform/infra` applied; two nodes `Ready`
- [ ] `terraform/platform` applied; four controllers Available
- [ ] `./script/sync-manifests.sh --check` passes
- [ ] `registry-ecr` removed from both overlays
- [ ] images pushed to ECR and real tags pinned
- [ ] Ingress has an `ADDRESS`; the four paths return 200

---

## What this costs

| | Monthly |
|---|---|
| EKS control plane | ~$73 |
| 2 × t3.medium | ~$60 |
| NAT gateway (`single_nat_gateway = true`) | ~$32 + data |
| ALB | ~$16 + LCUs |
| ECR, Route 53, ACM, S3 state | a few dollars |

Roughly **$185/month** at the floor. The kubeadm stack removes the $73 and the NAT.

---

## Tearing it down

**Order matters.** The ALB is owned by the Ingress, not by Terraform — destroy the
cluster first and the load balancer, its target groups and its security group are
orphaned, still billing, with no Terraform record of them.

```sh
kubectl delete -k k8s/overlays/uat        # removes the ALB first
kubectl delete -k k8s/overlays/prod
kubectl -n uat get ingress                # empty before continuing

./script/with-aws-env.sh terraform -chdir=terraform/platform destroy
./script/with-aws-env.sh terraform -chdir=terraform/infra destroy
```

The state bucket and lock table survive on purpose — `prevent_destroy` is set on both,
and they are shared by every stack.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `no valid credential sources found` | `.env` not loaded, or the wrong variable names. Use `with-aws-env.sh`. |
| `couldn't auto-discover subnets` | subnet tags missing — Terraform sets them, so this means the controller is looking at a VPC Terraform did not build |
| Ingress has no `ADDRESS` | the ALB controller is not running, or the Ingress has no class. Phase 4. |
| `ImagePullBackOff` | ECR is empty, or the tag does not exist. Phase 6. |
| HPA shows `<unknown>` | metrics-server missing. Phase 4. |
| Requests time out at the ingress | the NetworkPolicy node CIDR disagrees with `vpc_cidr`. `./script/sync-manifests.sh --check`. |
| `Error acquiring the state lock` | a previous apply died. Inspect with `aws dynamodb scan --table-name terraform-locks` before `terraform force-unlock`. |

Deeper detail: [terraform.md](terraform.md) for the stacks and the ownership boundary,
[deployment.md](deployment.md) for the manifests, [security.md](security.md) for the
NetworkPolicies.
