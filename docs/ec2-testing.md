# Testing on a single EC2 instance

A throwaway k3s cluster on one EC2 box. Cheaper than EKS, more realistic than a
laptop, and it is the only place you can properly test the thing the egress
NetworkPolicy exists for: the EC2 instance metadata endpoint.

> **This costs money while it runs.** A `t3.small` is roughly $0.02/hour
> (~$0.50/day) plus about $1.60/month for the disk, varying by region. Check
> current pricing, and see [Tear it down](#tear-it-down) before you start.
> Set a calendar reminder if you are prone to forgetting.

## 1. Launch the instance

| Setting | Value | Why |
|---|---|---|
| AMI | Ubuntu Server 24.04 LTS | k3s targets it; commands below assume `apt` |
| Type | `t3.small` minimum, `t3.medium` comfortable | 2 GB runs k3s + ingress-nginx + 2 pods, but tightly |
| Storage | 20 GB gp3 | the default 8 GB fills up with images |
| IAM instance profile | **none** | see [the IMDS test](#lesson-2-the-one-that-matters-on-ec2) — attach nothing you would mind a container reading |
| Key pair | one you have | you need SSH |

## 2. Security group

The default rules are wrong for this in both directions. You need exactly two
inbound rules, **both scoped to your own IP**, never `0.0.0.0/0`:

| Type | Port | Source |
|---|---|---|
| SSH | 22 | My IP |
| Custom TCP | 30000-32767 | My IP |

That second range is the Kubernetes NodePort range, which is how you will reach
the ingress controller. Your [security doc](security.md#still-outstanding)
already lists "scope the security group to the ingress controller's port
instead of leaving 30000-32767 open" as outstanding work — this is that
tradeoff, made deliberately, on a disposable box. Narrow it to the single port
once you know which one you got.

## 3. Install k3s

SSH in, then:

```sh
sudo apt update && sudo apt install -y git make

# Traefik is k3s's bundled ingress controller. This repo targets ingress-nginx
# (ingressClassName: nginx), so disable Traefik or the two will fight.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -

# k3s writes a root-owned kubeconfig; copy it somewhere your user can read.
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$USER" ~/.kube/config
chmod 600 ~/.kube/config

kubectl get nodes        # k3s installs kubectl for you
```

One node, and note its `ROLES` column: `control-plane,master`. That matters in
the next step.

## 4. Get the repo

The restructure lives on a branch, not `main`:

```sh
git clone https://github.com/virak-01/infra.git
cd infra
# The restructure may still be on a branch rather than main:
#   git checkout feature/new-layout
make envs
```

## 5. Deploy — and understand why `uat` will not work here

Try the honest thing first:

```sh
make deploy ENV=uat
kubectl -n uat get pods
```

The pods sit `Pending` and never move. `get pods` will not tell you why —
this will:

```sh
kubectl -n uat describe pod <name> | tail -20
```

```
0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector
```

That is the base's `nodeAffinity` rejecting control-plane nodes, doing exactly
its job. Your only node **is** the control plane, so nothing can be scheduled.
The rule is right; the cluster is too small for it.

Use the overlay built for this:

```sh
kubectl delete -k k8s/overlays/uat
make deploy ENV=ec2-test
kubectl -n uat get pods -w
```

[`k8s/overlays/ec2-test`](../k8s/overlays/ec2-test/kustomization.yaml) is the
same base with the affinity patched out and one replica each. It is **test
only** — and note what that costs you: the nodeAffinity rule is no longer being
exercised. To test that rule for real, add a second k3s agent node and go back
to `ENV=uat`.

## 6. Install the ingress controller

```sh
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml

kubectl -n ingress-nginx wait --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s
```

The `baremetal` variant is the right one here: the cloud variants provision a
LoadBalancer, which needs the AWS Load Balancer Controller you do not have.
This gives you a NodePort instead. Find it:

```sh
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

```
PORT(S)
80:31234/TCP,443:31890/TCP
        ^^^^^ this one
```

## 7. See it

From your laptop, using the instance's **public IP** and that NodePort:

```sh
curl -s http://<public-ip>:31234/employee | head -5
open http://<public-ip>:31234/employee
open http://<public-ip>:31234/user
```

If it hangs, the security group is the first suspect — confirm the port range
covers the NodePort you actually got, and that the source is your current IP
(which changes if you move networks).

## 8. Lesson 1: is NetworkPolicy actually enforced?

`make deploy` applied both policies. On kind's default CNI they would be
silently inert. k3s ships NetworkPolicy enforcement — but verify rather than
assume, because "looks protected and isn't" is the worst state to be in:

```sh
kubectl -n uat get networkpolicy

kubectl -n uat run probe --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -s --max-time 3 http://1.1.1.1
```

`deny-all-egress` selects every pod in the namespace, including this probe. So:

- **times out / empty** → the policy is enforced. Good.
- **returns a response** → the policy is decorative. Everything below is worse
  than it looks.

An IP is used deliberately — with egress denied, DNS is dead too, so a hostname
would fail for the wrong reason and teach you nothing.

## Lesson 2: the one that matters on EC2

`169.254.169.254` is the instance metadata endpoint. It is why
[`networkpolicy-egress.yaml`](../k8s/base/networkpolicy-egress.yaml) exists: it
is the standard path from "someone compromised a container" to "someone has
your AWS credentials."

On your laptop this address goes nowhere. Here it is live.

```sh
kubectl -n uat run imds --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- sh -c '
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 60" --max-time 3)
    curl -s -H "X-aws-ec2-metadata-token: $TOKEN" --max-time 3 \
      http://169.254.169.254/latest/meta-data/instance-id; echo'
```

With the policy working, this returns nothing. Now watch it fail — remove the
policy, re-run, and put it back:

```sh
kubectl -n uat delete networkpolicy deny-all-egress
# re-run the probe above: it now prints your instance id
make deploy ENV=ec2-test        # restores the policy
```

That difference is the entire argument for the egress policy, and it is worth
seeing once with your own eyes. If the instance had an IAM role attached,
swapping `instance-id` for `iam/security-credentials/` would have printed live
credentials instead — which is why step 1 says to attach none.

The token dance is IMDSv2. Modern instances require the `PUT` first; a naive
`GET` returns 401. Enforcing IMDSv2 is itself a mitigation, but a defence in
the pod network is the one that does not depend on instance configuration.

## Tear it down

```sh
# on the instance
/usr/local/bin/k3s-uninstall.sh
```

Then **terminate the instance** in the console, and confirm the EBS volume went
with it. Stopping is not enough — a stopped instance still bills for storage.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Pods `Pending` forever | Using `ENV=uat` on one node. See step 5. |
| `ImagePullBackOff` | Private ECR on k3s: usually the `ecr-creds` Secret is missing or its 12-hour token expired — recreate it (see docs/deployment.md). Otherwise check the tag exists: `aws ecr describe-images --region us-east-1 --repository-name employee-web --query 'imageDetails[].imageTags'` |
| Ingress has no `ADDRESS` | Expected with the baremetal controller — use the NodePort. |
| curl from laptop hangs | Security group source IP, or wrong NodePort. |
| `Unable to connect to the server` | kubeconfig not copied — step 3. |
| Pods `Evicted`, node `DiskPressure` | 8 GB disk. Rebuild with 20 GB. |
