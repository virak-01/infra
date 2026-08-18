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

## If your EC2 box is Ubuntu: install the tools first

Amazon Linux 2023 ships the AWS CLI and the SSM agent. A plain Ubuntu instance has
neither, and `terraform init` will succeed before failing on credentials — which makes
the missing CLI easy to miss.

**Do not run `sudo apt install awscli`**, which Ubuntu suggests when the command is
missing. That package is AWS CLI **v1** — years behind, and it lacks the EKS and SSO
support this project relies on. Install v2 from AWS:

```sh
case "$(uname -m)" in
  x86_64)  AWS_ARCH=x86_64  ; K8S_ARCH=amd64 ;;
  aarch64) AWS_ARCH=aarch64 ; K8S_ARCH=arm64 ;;
esac

sudo apt-get update -qq && sudo apt-get install -y -qq unzip curl

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/${K8S_ARCH}/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm /tmp/kubectl

aws --version            # aws-cli/2.x
kubectl version --client
```

The arch check matters: a Graviton instance (`t4g`, `m7g`) needs the `aarch64` and
`arm64` builds, and the x86 binaries fail there with `cannot execute binary file`.

---

## The simplest possible first run

Everything below this section is the full path: remote state, a locked backend, two
stacks, a controller layer. Worth having for a team. **Not worth having on day one.**

To just get a cluster, skip `bootstrap/` entirely and use local state:

```sh
# 1. credentials — attach an IAM role to the EC2 box you are on (see below)
aws sts get-caller-identity

# 2. local state instead of S3. Terraform only reads *.tf, so renaming disables it.
cd terraform/infra
mv backend.tf backend.tf.off

# 3. go
terraform init
terraform apply                                  # ~15 min, mostly EKS

# 4. talk to it
aws eks update-kubeconfig --region us-east-1 --name "$(terraform output -raw cluster_name)"
kubectl get nodes
```

Four steps, one stack. Then `cd ../platform` for the controllers when you want an
Ingress to work.

**What you give up**, and when it starts to matter:

| | Local state | Why you would eventually want S3 |
|---|---|---|
| Where state lives | `terraform.tfstate` on this box | lose the box, lose the ability to change or destroy anything it built |
| Locking | none | two concurrent applies corrupt the file |
| Sharing | one machine only | nobody else can run a plan |

None of that matters while it is one person on one box learning the shape of it. All of
it matters the moment a second person or a CI job appears.

### Storing state in S3 instead

One extra stack, then plain `terraform init` and `terraform apply` everywhere.

```sh
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1

# one-time: put your account id into the backend files
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/<ACCOUNT_ID>/$ACCOUNT/" terraform/*/backend.tf

# create the bucket and lock table. Once per account.
cd terraform/bootstrap
terraform init
terraform apply                 # no -var: the name derives from your account

# every stack after this needs no flags
cd ../infra
terraform init
terraform apply
```

The bucket name is `k8s-tfstate-<account-id>-<region>`, derived in `bootstrap` and
written literally into each `backend.tf` — which is what keeps `init` bare. Override
per command when it differs:

```sh
terraform init -backend-config="bucket=<other>" -backend-config="region=<other>"
```

**If you already applied with local state**, restore the backend file and add one flag:

```sh
cd terraform/infra
mv backend.tf.off backend.tf          # only if you renamed it earlier
terraform init -migrate-state
```

Terraform reads the local file, uploads it, and switches over. Answer `yes` when it
asks to copy. Nothing is lost by having started local.

> **If `bootstrap` already has state under a different bucket name**, plain `apply` now
> plans to replace the bucket and `prevent_destroy` stops it. That is the guard working.
> You do not need to run bootstrap again — the bucket exists. Read its name back with
> `terraform output -raw state_bucket` and use that.

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

## Running from an EC2 box instead

If you would rather not put credentials or tooling on your own machine, run everything
from an EC2 instance. That is a better security posture, not merely a convenient one:

| | Laptop | EC2 box |
|---|---|---|
| Credentials | long-lived access key in `.env` | instance profile via IMDS |
| Lifetime | until someone revokes it | minutes, rotated automatically |
| On disk | yes | nothing |
| Travels | yes | no |

**The box needs an IAM instance profile.** Without one you get this, which looks like a
credentials problem and is really a "no role attached" problem:

```
Error: No valid credential sources found
failed to refresh cached credentials, no EC2 IMDS role found,
operation error ec2imds: GetMetadata, http response error StatusCode: 404
```

A 404 there means IMDS *answered* — so the machine is EC2 — but there is no role to
return. On a laptop the address is unroutable and you would get a timeout instead.

### Create and attach the role

From **AWS CloudShell** — a browser shell with your console credentials already loaded,
so nothing has to be installed anywhere:

```sh
cat > /tmp/trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role --role-name k8s-ops \
  --assume-role-policy-document file:///tmp/trust.json

aws iam attach-role-policy --role-name k8s-ops \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam attach-role-policy --role-name k8s-ops \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name k8s-ops
aws iam add-role-to-instance-profile \
  --instance-profile-name k8s-ops --role-name k8s-ops

sleep 15   # instance profiles take a few seconds to propagate; associating
           # immediately fails with "Invalid IAM Instance Profile name"

aws ec2 associate-iam-instance-profile \
  --instance-id i-xxxxxxxx --iam-instance-profile Name=k8s-ops
```

Get the instance id from the box itself. IMDSv2 needs a token first — a plain GET
returns 401 where v1 is disabled:

```sh
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id
```

Then, back on the box — no reboot needed, credentials appear within seconds:

```sh
aws sts get-caller-identity     # Arn should read assumed-role/k8s-ops/i-xxxx
```

`AdministratorAccess` is not laziness here. These stacks create IAM roles and an OIDC
provider, and anything that can create an IAM role can create an administrator one and
assume it — so a Terraform runner is administrator-equivalent whatever policy you
attach. The real control is who can reach the box.

### On the box

**Do not create `.env`, and do not create `~/.aws/credentials`.** Either would replace
short-lived rotating credentials with something worse.
[`script/with-aws-env.sh`](../script/with-aws-env.sh) detects the instance profile and
passes straight through, so every command in this document works with no file present.

Two things to set, because a bare instance has neither:

```sh
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
```

Make them stick: `echo 'export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1' | sudo tee /etc/profile.d/aws-region.sh`

Then continue from **Phase 1**, skipping Phase 0.

> **If the box has a public IP and you narrow `public_access_cidrs`**, put that address
> in as a `/32` or the box cannot reach the EKS API endpoint it just created. Give it an
> Elastic IP first, or a stop/start will change the address and lock you out.

> **Running Terraform inside a container on that box?** The default IMDS hop limit of 1
> stops the request at the host network namespace and produces the same 404. Raise it:
> `aws ec2 modify-instance-metadata-options --instance-id i-xxxx --http-put-response-hop-limit 2`

---

## Phase 0 — Your machine

*Skip this entirely if you are using the ops box above.*

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
```

`terraform.tfvars` is committed, so it works as shipped. Three values are worth
reviewing before you apply:

| Variable | Why |
|---|---|
| `domain_name` | ships as `null`, which skips DNS and TLS entirely. Set a real domain only when you own one. |
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
