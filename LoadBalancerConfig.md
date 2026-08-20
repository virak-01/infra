# Load balancer configuration

How traffic reaches this cluster from the internet, and every piece of AWS that
has to be right for it to work.

This is the **kubeadm-on-EC2** path. On EKS most of it is automatic and you can
skip to [step 5](#5-install-the-controller); here nothing is, which is why this
file exists.

```
internet
   │
   ▼
Application Load Balancer          public subnets, one per AZ
   │                               scheme: internet-facing, listener :80
   ▼
EC2 node : NodePort                target-type: instance
   │                               (30000-32767)
   ▼
kube-proxy  ──►  employee-web / api-core-web / api-auth-web pod : 3000
```

Two facts drive every decision below:

- **The CNI is Calico**, an overlay network. Pod IPs exist only inside the
  cluster and are not routable from the VPC, so the ALB cannot address pods
  directly. It has to go through a node port.
- **There is no cloud controller.** Nothing watches for `type: LoadBalancer`
  Services and nothing mints IAM credentials on demand. Both are supplied by
  hand.

## 1. The VPC

Everything lives in one VPC. Confirm what you have:

```sh
aws ec2 describe-vpcs --region us-east-1 \
  --vpc-ids vpc-05b81b6a8bff35520 \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,Default:IsDefault}' --output table
```

| Field | Value |
|---|---|
| VPC | `vpc-05b81b6a8bff35520` |
| CIDR | `172.31.0.0/16` |
| Region | `us-east-1` |
| Subnets | 6 public, one per AZ |

**The CIDR is load-bearing inside the cluster too.**
`k8s/components/ingress-alb/kustomization.yaml` appends a NetworkPolicy rule
allowing pod traffic from that range, because an ALB using instance targets
arrives from a *node* address rather than from a pod or namespace. If the VPC
CIDR ever changes, that rule has to change with it or every health check is
silently dropped — the pods stay up, the target group goes unhealthy, and
nothing logs a reason.

It lives in the ALB component rather than in `k8s/base` precisely because it is
an ALB-and-account-specific value; an overlay served by ingress-nginx needs no
such rule and does not render one.

## 2. Subnets

An ALB needs at least two subnets in **different Availability Zones**, even
when the cluster is a single node. List them:

```sh
aws ec2 describe-subnets --region us-east-1 \
  --filters Name=vpc-id,Values=vpc-05b81b6a8bff35520 \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Public:MapPublicIpOnLaunch}' \
  --output table
```

The controller does not take a subnet list. It **discovers** subnets by tag,
and fails with `couldn't auto-discover subnets` if it finds none:

| Tag | Value | Meaning |
|---|---|---|
| `kubernetes.io/role/elb` | `1` | eligible for an internet-facing load balancer |
| `kubernetes.io/cluster/<clusterName>` | `shared` | belongs to this cluster |

```sh
aws ec2 create-tags --region us-east-1 \
  --resources subnet-0f0f4056b8cf996cf subnet-09aa2a752522da5e1 \
              subnet-03ce7b03b9ef73529 subnet-0b85e993a6c4343b9 \
              subnet-0acc8d5ca35643cc9 subnet-0b09b7f7f8d3c49d6 \
  --tags Key=kubernetes.io/role/elb,Value=1 \
         Key=kubernetes.io/cluster/company-kubeadm,Value=shared
```

> **Terraform already applied both tags** — see `modules/network/main.tf`, which
> stamps `kubernetes.io/role/elb` and `kubernetes.io/cluster/${cluster_name}` on
> every public subnet. Run the command above only for subnets Terraform does not
> manage. Re-tagging the ones it does is harmless but pointless.

**Tag all six, not the minimum two.** An ALB only delivers to nodes in an AZ
that is enabled on the load balancer; a node in an un-enabled AZ registers
successfully and then sits permanently `unused`, which looks like a broken app
rather than a placement problem. Tagging every AZ removes the failure mode, and
an ALB spanning six AZs costs exactly what one spanning two costs.

**`<clusterName>` IS NOT KUBEADM'S CLUSTER NAME.** It is an arbitrary label, and
its only job is to match the subnet tag — so it must equal Terraform's
`cluster_name` (`company-kubeadm`), NOT the `kubernetes` that kubeadm-config
reports. Passing kubeadm's name instead is a silent failure: the controller
authenticates, lists the subnets, rejects every one, and loops on

```
couldn't auto-discover subnets: unable to resolve at least one subnet.
Evaluated 3 subnets: 3 are tagged for other clusters
```

Read the authoritative value from Terraform rather than from the cluster:

```sh
grep cluster_name terraform/infra-kubeadm/terraform.tfvars
```

## 3. Security groups

Two groups, with one rule each that matters.

**The ALB's group** is created and managed by the controller. It allows `:80`
from the internet.

**The node's group** must allow the NodePort range *from the ALB's group* —
not from the internet:

```sh
# find the ALB's security group after it exists
aws elbv2 describe-load-balancers --region us-east-1 \
  --query 'LoadBalancers[].{Name:LoadBalancerName,SG:SecurityGroups}' --output table

aws ec2 authorize-security-group-ingress --region us-east-1 \
  --group-id <node-sg-id> \
  --protocol tcp --port 30000-32767 \
  --source-group <alb-sg-id>
```

Source-group rather than CIDR is what makes this a real boundary: an ALB
terminates the connection and re-originates it from its own network
interfaces, so the node sees the ALB's group as the source and can refuse
everything else. (An NLB with instance targets preserves the client's IP
instead, which would force the node group back open to the internet — that is
the reason this setup uses an ALB.)

Once the ALB serves traffic, remove the rule that exposes NodePorts publicly:

```sh
aws ec2 revoke-security-group-ingress --region us-east-1 \
  --group-id <node-sg-id> \
  --protocol tcp --port 30000-32767 --cidr <your-ip>/32
```

> Do this **last**. Until the ALB is serving, that rule is the only way in, and
> revoking it early leaves the cluster unreachable except through the AWS
> console. Keep the SSH rule on port 22 either way.

## 4. Credentials

The controller calls the ELB and EC2 APIs, so it needs AWS credentials. Three
ways to supply them, in descending order of preference:

| Method | Where it works | Notes |
|---|---|---|
| IRSA | EKS only | No stored secret, rotates automatically. Unavailable here. |
| Instance profile | Any EC2 node | Readable via IMDS by anything on the node. |
| Static keys in a Secret | Anywhere | No rotation; needs `iam:CreatePolicy` only, not `iam:CreateRole`. |

Both non-IRSA options need the AWS-published policy attached to the identity.

> **PIN ONE VERSION AND USE IT TWICE** — here, and for the chart in step 5.
> Every controller release adds ELB/EC2 actions, so a policy older than the
> running controller fails with `AccessDenied` **at the first reconcile**: never
> at install, never in the startup logs, and only once a real Ingress exists.
> This doc pinned the policy at v2.7.2 while the chart floated to latest, which
> put a v2.7.2 policy under a v3.5.0 controller. Move both together or neither.

```sh
LBC_VERSION=v3.5.0        # must match the GitVersion the controller logs at startup

curl -o iam-policy.json \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json"

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json
```

Updating a policy that already exists — `create-policy` fails once it does:

```sh
aws iam create-policy-version \
  --policy-arn arn:aws:iam::866409326838:policy/AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json --set-as-default
```

A managed policy holds at most 5 versions; `aws iam delete-policy-version` an
old one if that errors.

**Instance profile** — fewer moving parts, but see the warning below:

```sh
cat > trust.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
                  "Principal": { "Service": "ec2.amazonaws.com" },
                  "Action": "sts:AssumeRole" }] }
EOF

aws iam create-role --role-name k8s-alb-controller-node \
  --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name k8s-alb-controller-node \
  --policy-arn arn:aws:iam::866409326838:policy/AWSLoadBalancerControllerIAMPolicy
aws iam create-instance-profile --instance-profile-name k8s-alb-controller-node
aws iam add-role-to-instance-profile \
  --instance-profile-name k8s-alb-controller-node \
  --role-name k8s-alb-controller-node
aws ec2 associate-iam-instance-profile --region us-east-1 \
  --instance-id <instance-id> \
  --iam-instance-profile Name=k8s-alb-controller-node
```

> **This contradicts [docs/ec2-testing.md](docs/ec2-testing.md).** That doc
> specifies *no* instance profile — "attach nothing you would mind a container
> reading" — and its IMDS exercise depends on the node having no credentials
> worth stealing. Attaching one makes these permissions readable from
> `169.254.169.254` by anything on the node. The egress NetworkPolicy blocks
> IMDS for `employee-web` and `user-web`, so those two are covered; nothing
> else on the node is. This is the concrete price of running an ALB on kubeadm
> rather than EKS.

**Static keys** — the fallback when the account does not permit role creation,
and consistent with how `script/aws-creds.sh` already supplies ECR credentials:

```sh
kubectl -n kube-system create secret generic aws-alb-credentials \
  --from-literal=AWS_ACCESS_KEY_ID='...' \
  --from-literal=AWS_SECRET_ACCESS_KEY='...'
```

Never paste real keys into this file — it is committed. Supply them at the
command line — `script/aws-creds.sh` avoids even that, prompting without echo and
writing a mode-600 file rather than passing the value as a kubectl argument where it
would be visible in `ps`.

Then add `--set 'envFrom[0].secretRef.name=aws-alb-credentials'` to the Helm
command below. The key names are the ones the AWS SDK reads directly, so no
mapping is involved.

## 5. Install the controller

```sh
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# THE CHART VERSION IS NOT THE CONTROLLER VERSION. Find the chart shipping the
# $LBC_VERSION pinned in step 4 — column 2 is the chart, column 3 the app:
helm search repo eks/aws-load-balancer-controller --versions \
  | awk -v v="${LBC_VERSION#v}" '$3 == v'

# upgrade --install, not install: re-running a plain `install` on an existing
# release fails with "cannot re-use a name that is still in use" and changes
# nothing, while `rollout status` below still reports the OLD pod as healthy.
#
# --version is what keeps the chart from floating to latest while the IAM policy
# stays frozen at whatever step 4 fetched.
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --version <chart-version-from-the-search-above> \
  --set clusterName=company-kubeadm \
  --set region=us-east-1 \
  --set vpcId=vpc-0a10f079fdb9a18c3 \
  --set 'envFrom[0].secretRef.name=aws-alb-credentials'

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

`region` and `vpcId` are **required off EKS**. The controller normally reads
them from cluster metadata that only EKS provides; omit either and the pod
starts healthy and then does nothing at all.

## 6. What the manifests already carry

No change is needed here — this is what the repo renders, and why.

| Setting | Value | Reason |
|---|---|---|
| `ingressClassName` | `alb` | selects this controller |
| `alb.../target-type` | `instance` | Calico pod IPs are not VPC-routable, so `ip` cannot work |
| `alb.../scheme` | `internet-facing` | public ALB |
| Service `type` | `NodePort` | required by `instance` targets; a ClusterIP has no node port |
| `alb.../healthcheck-path` | per Service | `/` on employee-web, `/api/health` on both APIs — set on each Service, since one target group is created per backend and each serves only its own base path |

The health check path is the subtle one. Annotations on a **Service** override
the same annotation on the Ingress, which is the only way to give several
backends different paths from a single Ingress. A shared `/` would 404 on the
APIs and mark two thirds of the fleet unhealthy.

To fall back to the in-cluster ingress-nginx controller instead, change the
component line in both overlays from `../../components/aws` to:

```yaml
components:
  - ../../components/registry-ecr     # keep: images still come from ECR
  - ../../components/ingress-nginx    # class nginx instead of alb
```

`components/aws` is only an umbrella over `registry-ecr` + `ingress-alb`, so
this swaps the edge and keeps the pull credentials. The ALB annotations and the
`NodePort` Service type come from `ingress-alb` and simply do not render;
Services stay ClusterIP, which is what ingress-nginx wants.

Both overlays must agree — they share a cluster, and two ingress classes
claiming the same hosts is resolved by whichever object was created first,
silently.

## 7. Verify

```sh
kubectl -n prod get ingress company-web -w        # ADDRESS fills in, ~2-3 min

ALB=$(kubectl -n prod get ingress company-web \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -I http://$ALB/
curl -I http://$ALB/api/health
```

Both return `200`. The trailing slash matters — each site serves under its own
base path and the Ingress does not rewrite.

```sh
aws elbv2 describe-target-groups --region us-east-1 \
  --query 'TargetGroups[?VpcId==`vpc-0a10f079fdb9a18c3`].{Name:TargetGroupName,Port:Port,Path:HealthCheckPath}' \
  --output table
```

Expect two target groups with **different** health check paths. Identical paths
mean the per-Service annotations did not render.

## 8. When it fails

Everything here fails silently — Kubernetes accepts the object and AWS simply
never builds anything. Read the controller log first:

```sh
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
```

| Symptom | Cause | Fix |
|---|---|---|
| `ADDRESS` stays empty | no credentials, or untagged subnets | steps 2 and 4 |
| `couldn't auto-discover subnets` | missing tag, or `clusterName` mismatch | step 2 |
| `AccessDenied` in the log | policy missing, or attached after the pod started | step 4, then `rollout restart` |
| ALB returns 503 | targets unhealthy — node SG, or NetworkPolicy CIDR | steps 3 and 1 |
| Targets show `unused` | node is in an AZ not enabled on the ALB | step 2 |
| One site 200, the other 503 | both target groups share a health check path | step 6 |
| Healthy but assets 404 | missing trailing slash | step 7 |

## 9. Cost

An ALB is roughly **$16–18/month** in `us-east-1` before LCU charges, billed
whether or not traffic flows. The ingress-nginx NodePort path costs nothing and
is a reasonable default for a learning cluster; delete the ALB when it is not
being used, since removing the Ingress alone does not remove it.



#### Node
kubectl -n kube-system rollout restart deployment aws-load-balancer-controller
kubectl -n kube-system rollout status deployment aws-load-balancer-controller