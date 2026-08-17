# Bringing this repo up in a new AWS account

Everything in this repo points at account `043309361013`, region `us-east-1`,
and the domain `devops-selft-learning.xyz`. This is the ordered list of what to
create in a fresh account and what to change here so it points at yours.

Read [`deployment.md`](deployment.md) for how the manifests are shaped,
[`../LoadBalancerConfig.md`](../LoadBalancerConfig.md) for the VPC/subnet/ALB
detail, and [`autoscaling.md`](autoscaling.md) for the ASG. This file is the
bootstrap order and the substitution list; it does not repeat them.

## Decide this first: which kind of cluster

The answer changes four later steps, so settle it before creating anything.

| | **EKS** | **kubeadm/k3s on EC2** |
|---|---|---|
| Pull credentials | node role, no Secret | `registry-ecr` component + IAM user |
| Cluster Autoscaler | **managed node groups instead — see the warning below** | `k8s/cluster/aws` as written |
| CNI | VPC CNI (default) | Calico, installed by hand |
| Overlay `components:` | `../../components/ingress-alb` | `../../components/aws` |
| Cost floor | ~$75/mo control plane + nodes | nodes only |

> **The Cluster Autoscaler in this repo does not run on EKS.**
> [`deployment.yaml:34-39`](../k8s/cluster/aws/cluster-autoscaler/deployment.yaml#L34-L39)
> pins the pod to a control-plane node with a `nodeSelector` and a matching
> toleration. EKS control-plane nodes are managed by AWS and are not in your
> cluster, so nothing matches that selector and the pod sits **Pending forever** —
> no error, no event that names the real cause. On EKS use managed node group
> autoscaling, or delete the `nodeSelector`/`tolerations` block and give the
> ServiceAccount an IRSA role. `make cluster` applies this on every `make deploy`,
> so on EKS either fix it or skip the target.

## 0. Prerequisites on your machine

```sh
aws --version          # v2
kubectl version --client   # 1.27+, for the built-in kustomize
brew install kubeconform   # optional, for `make validate`
```

Point the CLI at the new account and confirm you are where you think you are —
every step below writes into whatever account this prints:

```sh
aws configure           # or: export AWS_PROFILE=<new-account>
aws sts get-caller-identity
```

Capture the two values everything else derives from:

```sh
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=us-east-1        # or your region
echo "$ACCOUNT_ID / $AWS_REGION"
```

## 1. ECR repositories

Four repositories, matching the `newName:` entries in both overlays. `website`
serves both sites today; `employee-web` and `user-web` are named in the README
but do not exist yet.

```sh
for repo in website auth core; do
  aws ecr create-repository \
    --repository-name "$repo" \
    --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability IMMUTABLE
done
```

`IMMUTABLE` is worth the friction. This repo's rule is *never reuse a tag* —
nodes cache layers, so one tag can mean two different images across the fleet,
and a rollback then lands somewhere undefined. Immutable tags make that a
push-time error instead of a mystery at 3am.

**This repo does not build images.** Push them from wherever the site source
lives before deploying, then pin the tags in the overlays:

```sh
aws ecr describe-images --region "$AWS_REGION" --repository-name website \
  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[].imageTags' --output text
```

## 2. Certificate and DNS

The ALB terminates TLS with an ACM certificate, and the ARN is named
explicitly in [`ingress-alb`](../k8s/components/ingress-alb/kustomization.yaml#L43).

```sh
aws acm request-certificate \
  --region "$AWS_REGION" \
  --domain-name example.com \
  --subject-alternative-names '*.example.com' \
  --validation-method DNS
```

One wildcard covers the apex plus `uat.`, `uat-api.` and `api.`, which is why
uat and prod share a certificate. **The certificate must be in the same region
as the ALB** — an ACM cert in another region cannot be attached, and the error
appears on the Ingress rather than on the certificate.

Validate it (add the CNAME ACM gives you to your hosted zone), then wait:

```sh
aws acm wait certificate-validated --region "$AWS_REGION" --certificate-arn <arn>
```

DNS records come *after* the ALB exists, in step 7 — the ALB's hostname is what
they point at. If you have no domain, skip this whole step: leave the hosts
commented out, drop the `certificate-arn` and `ssl-redirect` annotations, and
reach the ALB by its own hostname over HTTP.

## 3. Network

Follow [`LoadBalancerConfig.md` §1-3](../LoadBalancerConfig.md). The part that
silently breaks everything if missed is subnet tagging — the controller
*discovers* subnets by tag, and untagged subnets produce an Ingress that stays
`ADDRESS`-less with no useful event:

```sh
aws ec2 create-tags --resources <public-subnet-ids> \
  --tags Key=kubernetes.io/role/elb,Value=1
aws ec2 create-tags --resources <private-subnet-ids> \
  --tags Key=kubernetes.io/role/internal-elb,Value=1
```

At least two subnets in different Availability Zones. An ALB will not come up in
one AZ.

## 4. The cluster

**EKS:**

```sh
eksctl create cluster --name <name> --region "$AWS_REGION" \
  --nodegroup-name workers --nodes 2 --nodes-min 2 --nodes-max 6 \
  --with-oidc
aws eks update-kubeconfig --region "$AWS_REGION" --name <name>
```

**kubeadm on EC2:** see [`ec2-testing.md`](ec2-testing.md). Afterwards install a
CNI, matching the pod CIDR the cluster was initialised with:

```sh
kubectl -n kube-system get cm kubeadm-config -o yaml | grep -i podSubnet
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
kubectl get nodes -w
```

Either way, do not continue until at least one **schedulable** node is `Ready`.
A single-node cluster with only a tainted control plane leaves every pod Pending,
and the pod events blame resources rather than the taint.

```sh
kubectl get nodes -o wide
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

`metrics-server` is not optional here: the HPAs in this repo report
`<unknown>/70%` without it and never scale.

## 5. The AWS Load Balancer Controller

Full detail in [`LoadBalancerConfig.md` §4-5](../LoadBalancerConfig.md#4-credentials).
In outline:

```sh
curl -o iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

eksctl create iamserviceaccount --cluster <name> --region "$AWS_REGION" \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy" \
  --approve

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=<name> \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

On a self-managed cluster there is no IRSA, so attach the policy to the node
instance profile instead and set `--set region=` and `--set vpcId=` explicitly —
the controller cannot infer them off EKS.

```sh
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

**Without this controller the Ingress does nothing.** The API server accepts it,
no controller claims it, and you get no routing, no address, and no error
anywhere. That is the single most common way this repo appears broken.

## 6. Pull credentials

**EKS** — attach `AmazonEC2ContainerRegistryReadOnly` to the node group role and
create no Secret. Then point the overlays at `ingress-alb` alone rather than the
`aws` umbrella (step 8).

**Anything else** — an IAM user scoped to one action, used by the refresh
CronJob in the `registry-ecr` component:

```sh
aws iam create-user --user-name ecr-pull-refresher
aws iam put-user-policy --user-name ecr-pull-refresher \
  --policy-name ecr-token --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"}]}'
aws iam create-access-key --user-name ecr-pull-refresher
```

A user, not the node's instance profile, and deliberately: this repo's
[`networkpolicy-egress.yaml`](../k8s/base/networkpolicy-egress.yaml) blocks
`169.254.169.254` so a compromised container cannot read the node's IAM role.
A narrow, revocable credential is the trade for keeping that block intact.

`ecr:GetAuthorizationToken` only mints the token. The **pull** itself is
authorised by the node's own role or by the ECR repository policy, so nodes
still need `AmazonEC2ContainerRegistryReadOnly` (or an equivalent repository
policy) even on non-EKS clusters.

## 7. Change the values in this repo

Every account-specific value, exhaustively:

| Value | Files |
|---|---|
| Account ID `043309361013` | [`Makefile:34`](../Makefile#L34), [`overlays/prod:25,28,31,34`](../k8s/overlays/prod/kustomization.yaml#L25), [`overlays/uat:43,46,49,52`](../k8s/overlays/uat/kustomization.yaml#L43), [`ingress-alb:43`](../k8s/components/ingress-alb/kustomization.yaml#L43), [`ecr-credentials.yaml:149`](../k8s/components/registry-ecr/ecr-credentials.yaml#L149) |
| Region `us-east-1` | [`Makefile:33`](../Makefile#L33), [`ecr-credentials.yaml:147`](../k8s/components/registry-ecr/ecr-credentials.yaml#L147), [`cluster-autoscaler/deployment.yaml:102`](../k8s/cluster/aws/cluster-autoscaler/deployment.yaml#L102), plus every registry hostname and the cert ARN |
| Certificate ARN | [`ingress-alb:43`](../k8s/components/ingress-alb/kustomization.yaml#L43) |
| Hostnames | [`overlays/uat:112,115`](../k8s/overlays/uat/kustomization.yaml#L112); prod's are commented out at [`overlays/prod:48-54`](../k8s/overlays/prod/kustomization.yaml#L48) |
| ASG name `k8s-learning-workers` | [`cluster-autoscaler/deployment.yaml:74`](../k8s/cluster/aws/cluster-autoscaler/deployment.yaml#L74) — with `2:6` matching the ASG's real MinSize/MaxSize |
| Autoscaler image tag | [`deployment.yaml:54`](../k8s/cluster/aws/cluster-autoscaler/deployment.yaml#L54) — **must match your control plane's minor version** |
| Argo CD `repoURL` | [`argocd/application-prod.yaml:19`](../argocd/application-prod.yaml#L19), [`application-uat.yaml`](../argocd/application-uat.yaml) |
| Image tags | `newTag:` in both overlays — tags that exist in *your* ECR |

The account ID and region are mechanical (macOS `sed`; drop the `''` on Linux):

```sh
grep -rl 043309361013 k8s/ Makefile | xargs sed -i '' "s/043309361013/$ACCOUNT_ID/g"
grep -rl us-east-1    k8s/ Makefile | xargs sed -i '' "s/us-east-1/$AWS_REGION/g"
```

The certificate ARN, hostnames and ASG name are not — set those by hand, then
confirm nothing from the old account survives:

```sh
grep -rn "043309361013\|devops-selft-learning\|k8s-learning-workers" k8s/ Makefile
```

Render before applying. This costs nothing and catches every typo above:

```sh
make render ENV=uat | grep -E 'image:|certificate-arn|ingressClassName'
make validate ENV=uat
```

## 8. Pick the cloud components

One line per overlay, in both [`k8s/overlays/uat`](../k8s/overlays/uat/kustomization.yaml)
and [`prod`](../k8s/overlays/prod/kustomization.yaml). They must agree — the two
share a cluster, and two ingress classes claiming the same hosts is resolved by
whichever object was created first, silently.

```yaml
# EKS: node role supplies pull credentials, so no registry component
components:
  - ../../components/ingress-alb

# kubeadm/k3s on EC2: ALB + ECR pull credentials (the default, unchanged)
components:
  - ../../components/aws

# any cluster, served by ingress-nginx instead of an ALB
components:
  - ../../components/registry-ecr
  - ../../components/ingress-nginx
```

## 9. Deploy

UAT first. The order matters:

```sh
kubectl config current-context             # confirm the target cluster

make cluster                               # 1. cluster add-ons (skip on EKS — see the warning)
make deploy     ENV=uat                    # 2. namespace, workloads, Ingress, CronJob
make aws-creds  ENV=uat                    # 3. prompts for the IAM key (not echoed)
make ecr-secret ENV=uat                    # 4. mints ecr-creds by running the CronJob now
make app-config ENV=uat                    # 5. website-config ConfigMap + restart
make rollout    ENV=uat                    # 6. wait for every Deployment
```

Steps 3-4 are for non-EKS clusters only. The pod spec carries
`imagePullSecrets: [ecr-creds]`, and that Secret does not exist until step 4 —
so **pods sit in `ImagePullBackOff` between steps 2 and 4, and that is
expected**, not a failure. Step 5 restarts them, which also clears the backoff.

`make app-config` needs `k8s/overlays/uat/app-config.env`; copy it from
`app-config.env.example`. It is gitignored, so Argo CD never sees it and it must
be applied out of band on every cluster.

## 10. DNS, now that the ALB exists

```sh
kubectl -n uat get ingress company-web \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Add Route 53 **ALIAS** records for each host pointing at that name — ALIAS and
not CNAME, because DNS forbids a CNAME at a zone apex. With no domain, use
`nip.io` and skip Route 53 entirely:

```sh
make deploy ENV=uat HOST=uat.$(curl -s ifconfig.me).nip.io
```

`HOST` is applied after the manifests and is not committed, so `make render`
shows the placeholder and Argo CD reverts it on the next sync. That is fine
while sync is manual.

## 11. Verify

```sh
make current ENV=uat
kubectl -n uat get pods,svc,ingress

ALB=http://$(kubectl -n uat get ingress company-web \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for p in / /api /api/auth /api/health; do
  printf "%-16s " "$p"; curl -s -m 10 -o /dev/null -w "%{http_code}\n" "$ALB$p"
done
```

Then promote: set the **same** tags in `k8s/overlays/prod`, `make diff ENV=prod`,
and `make deploy rollout ENV=prod`.

## 12. Argo CD (optional)

See [`argocd.md`](argocd.md). Update `repoURL` in both Applications to your fork
before applying them, or Argo CD will sync this repo's original and quietly undo
every change from step 7.

## Checklist

- [ ] `aws sts get-caller-identity` shows the new account
- [ ] ECR repositories exist and hold the tags the overlays name
- [ ] ACM certificate **issued** and in the ALB's region
- [ ] Subnets tagged `kubernetes.io/role/elb=1`
- [ ] At least one schedulable node `Ready`; `metrics-server` running
- [ ] `aws-load-balancer-controller` Deployment available
- [ ] Every value in step 7 replaced — the final `grep` returns nothing
- [ ] Both overlays name the same components
- [ ] Ingress has an `ADDRESS`; the three paths return 200
- [ ] Argo CD `repoURL` points at your fork

## Tearing it down

Delete the Kubernetes objects **before** the cluster. The ALB is owned by the
Ingress, not by CloudFormation — delete the cluster first and the load balancer,
its target groups and its security group are orphaned, billing quietly.

```sh
kubectl delete -k k8s/overlays/uat
kubectl delete -k k8s/overlays/prod
kubectl -n uat get ingress    # empty before continuing
eksctl delete cluster --name <name> --region "$AWS_REGION"
```

Then remove the ECR repositories, the ACM certificate, the IAM user from step 6,
and `AWSLoadBalancerControllerIAMPolicy`.
