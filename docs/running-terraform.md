# Running Terraform

The command sequence, what each stack does, and every error this setup actually
produces — with the cause rather than a guess.

For the ownership boundary (why Terraform stops at the load balancer) and the two
cluster styles, see [terraform.md](terraform.md). For a brand-new AWS account start at
[new-aws-account.md](new-aws-account.md).

---

## The four stacks

```
terraform/
  bootstrap/       the S3 state bucket. LOCAL state. Once per account.
  infra/           VPC · ECR · ACM · EKS cluster · IRSA roles
  infra-kubeadm/   the same platform on EC2 + kubeadm. Alternative to infra.
  platform/        the 4 in-cluster controllers, via Helm. AFTER infra.
```

Each writes a different key in the shared bucket, so they cannot destroy each other.
`bootstrap` is separate because a stack cannot hold the bucket its own state lives in.

Pick **either** `infra` or `infra-kubeadm` — running both means two clusters and two
bills.

---

## One-time setup

Three things, in this order. Skipping any of them produces one of the errors below.

```sh
# 1. credentials
aws sts get-caller-identity          # must print an Arn, not an error

# 2. the upstream IAM policy — gitignored, so a fresh clone does not have it
./script/fetch-policies.sh

# 3. point the backends at your state bucket
cd terraform/bootstrap
terraform init
terraform apply                       # no -var: the name derives from your account
cd ../..
./script/tf-backend.sh --write        # writes that bucket into every backend.tf
```

`tf-backend.sh` exists because a backend block accepts no variables — Terraform reads
it before evaluating anything else — so the bucket must be a literal. The script finds
the real bucket, checks it is reachable, and writes it in.

---

## The run

```sh
cd terraform/infra

terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

**15–20 minutes**, nearly all of it EKS building the control plane.

`terraform.tfvars` is committed and works as shipped, so there is no copy step. Two
values are worth reviewing first:

| | Shipped | Why |
|---|---|---|
| `domain_name` | `null` | skips DNS and TLS. With `create_zone = false` a real domain triggers a Route 53 **lookup** that fails unless you own it. |
| `public_access_cidrs` | `["0.0.0.0/0"]` | the Kubernetes API endpoint is internet-reachable — authenticated, but reachable. Narrow it once things work. |

Then cluster access and the controllers:

```sh
aws eks update-kubeconfig --region us-east-1 --name "$(terraform output -raw cluster_name)"
kubectl get nodes

cd ../platform
terraform init
terraform apply
kubectl -n kube-system get deploy      # 4 controllers Available
```

`platform` is a separate apply on purpose: the helm and kubernetes providers need
cluster credentials to build a plan, and in one root module those are attributes of a
cluster that does not exist during the first plan.

---

## Errors, and what actually causes them

Every one of these has been hit in this repo.

### `No valid credential sources found` … `no EC2 IMDS role found … StatusCode: 404`

On EC2 with **no IAM instance profile attached**. A 404 means IMDS answered — so the
machine is EC2 — but there is no role to return. On a laptop the address is unroutable
and you get a timeout instead. Attach a role; see
[new-aws-account.md](new-aws-account.md#running-from-an-ec2-box-instead).

### `Backend configuration changed`

`backend.tf` differs from what the last `init` cached in `.terraform/`. Nothing is
wrong — Terraform is asking which you meant:

```sh
terraform init -reconfigure     # discard the old association (no state to keep)
terraform init -migrate-state   # copy existing state to the new backend
```

Use `-migrate-state` only if the previous backend held real resources.

### `InvalidBucketName: The specified bucket is not valid`

`backend.tf` still contains the literal `<ACCOUNT_ID>` placeholder — `<` and `>` are
not legal in an S3 bucket name.

```sh
./script/tf-backend.sh --write
```

### `S3 bucket "…" does not exist`

The name in `backend.tf` is well-formed but names no bucket you own. Usually the
convention `k8s-tfstate-<account>-<region>` disagreeing with whatever `bootstrap`
actually created.

```sh
aws s3 ls | grep tfstate        # the real name
./script/tf-backend.sh --write  # or --bucket <name> to choose
```

### `Instance cannot be destroyed … lifecycle.prevent_destroy`

You applied `bootstrap` with a **different** bucket name than the one in its state. An
S3 bucket name is `ForceNew`, so a change means destroy-and-recreate, and the guard
stops Terraform deleting the bucket holding your state.

That is the guard working. You do not need to run `bootstrap` again — the bucket
exists:

```sh
terraform -chdir=terraform/bootstrap output -raw state_bucket
```

### `Invalid for_each argument … known only after apply`

`for_each` keys become resource addresses, so the full key set must be known at **plan**
time. Deriving them from something that does not exist until apply — an ASG name, an
ARN — cannot work. `count` needs only a known length, so it is the fix wherever the
count itself is a constant.

### `Invalid function argument … while calling file(path)`

`./script/fetch-policies.sh` has not run. The load balancer controller's IAM policy is
upstream's, pinned, and gitignored, so a fresh clone does not have it. Failing here is
deliberate — the alternative is attaching an empty policy and discovering it much later
as an `AccessDenied` at ALB-creation time.

### `expected length of user_data to be in the range (0 - 16384)`

EC2 caps instance user-data at 16 KB. The kubeadm bootstrap embeds both shell scripts
base64-encoded inside one document, and base64 inflates by a third — the control-plane
document renders to about 18 KB.

Fixed by gzipping: `user_data_base64 = base64gzip(templatefile(...))`. cloud-init
detects the gzip magic bytes and decompresses on its own, so nothing on the instance
changes, and the documents drop to roughly 11 KB and 10 KB.

Worth knowing if you edit `script/bootstrap/*.sh`: those files are embedded verbatim,
so comments there consume the budget. There is comfortable headroom now, but it is not
unlimited — if you hit this again, the next step is fetching the scripts from S3 at
boot rather than embedding them.

### `InvalidKeyPair.NotFound: The key pair 'x' does not exist`

`key_name` in `terraform.tfvars` names an EC2 key pair that is not in this account or
this region. Key pairs are regional — one created in `us-west-2` is invisible from
`us-east-1`.

It fails at `RunInstances`, so the VPC, subnets and security groups are already built.
Nothing needs cleaning up; fix the value and re-apply.

`key_name = null` is the shipped default and needs no key at all — the node roles carry
`AmazonSSMManagedInstanceCore`, so Session Manager reaches any node:

```sh
aws ssm start-session --target "$(terraform output -raw control_plane_instance_id)"
```

To use SSH, create the pair first — Terraform deliberately does not, because a key pair
resource puts the private key in state:

```sh
aws ec2 create-key-pair --key-name company-kubeadm \
  --query KeyMaterial --output text > ~/.ssh/company-kubeadm.pem
chmod 600 ~/.ssh/company-kubeadm.pem
```

### The instance already exists and I have no key for it

**A key pair cannot be added to a running instance.** AWS injects the public key exactly
once, at first boot, through cloud-init — there is no API to attach one afterwards, and
setting `key_name` and re-applying would *replace* the instance.

Use Session Manager, which needs no key:

```sh
aws ssm start-session --target "$(terraform output -raw control_plane_instance_id)"
sudo su - ubuntu        # sessions land as ssm-user
```

If the console's Session Manager tab is greyed out, the instance has no instance
profile — which is what happens when it was created by hand rather than by this stack:

```sh
aws ssm describe-instance-information \
  --query "InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}" --output table

aws ec2 associate-iam-instance-profile \
  --instance-id i-0abc123 --iam-instance-profile Name=<profile>
```

To get SSH onto a node that is already running, append the key from inside a session:

```sh
sudo -u ubuntu tee -a /home/ubuntu/.ssh/authorized_keys <<< "ssh-ed25519 AAAA... you@laptop"
```

### `Error acquiring the state lock`

A previous apply died holding the lock. Inspect before breaking it:

```sh
aws s3 ls "s3://<bucket>/infra/" --recursive | grep lock
terraform force-unlock <lock-id>       # only when no apply is running
```

### `Warning: Deprecated Parameter … dynamodb_table`

Already fixed — the backends use `use_lockfile = true`, which locks with an object in
the state bucket. If you still see it, your checkout predates that change.

---

## Reading a plan before you trust it

```sh
terraform plan -out=tfplan            # write it
terraform show tfplan | head -50      # read it
terraform apply tfplan                # apply exactly that
```

Applying a **saved** plan ignores any `-var` flags — the values are baked in. That is
what makes plan-then-apply safe: what you reviewed is what runs.

Things worth looking for before an apply:

- **anything `must be replaced`** — destroy-and-recreate. On a cluster or a bucket that
  is not what you want.
- **a resource count far from what you expect** — usually a `count` or `for_each`
  reading a different value than you think.
- **`known after apply` on something you supplied** — a variable is not reaching where
  you think it is.

---

## Destroying

**Order matters.** The ALB is owned by the Ingress, not by Terraform — destroy the
cluster first and the load balancer, its target groups and its security group are
orphaned, still billing, with no Terraform record of them.

```sh
cd "$(git rev-parse --show-toplevel)"      # -chdir is relative to HERE

kubectl delete -k k8s/overlays/uat
kubectl delete -k k8s/overlays/prod
kubectl -n uat get ingress                 # empty before continuing

terraform -chdir=terraform/platform destroy
terraform -chdir=terraform/infra destroy
```

`-chdir` is resolved against your current directory, so running it from inside
`terraform/infra` looks for `terraform/infra/terraform/infra` and fails. From inside a
stack, just `terraform destroy`.

`bootstrap` is left alone — `prevent_destroy` is set on the bucket and it is shared by
every stack.

---

## Conventions in this code

Worth knowing before editing:

| | |
|---|---|
| `variables.tf` / `outputs.tf` | every module, no exceptions — resources live in concern-named files (`cluster.tf`, `node_groups.tf`, `addons.tf`) |
| `providers.tf` | `terraform{}` + `provider{}` at each root, separate from module calls |
| `versions.tf` | provider constraints, per module |
| `backend.tf` | literal bucket and region, overridable with `-backend-config` |
| `terraform.tfvars` | **committed** — the values are configuration, not credentials. Anything sensitive goes in `secrets.tfvars`, which is ignored. |
| paths inside modules | `path.module`, never a bare relative path — a relative path resolves against the *root* module and breaks when called from elsewhere |
