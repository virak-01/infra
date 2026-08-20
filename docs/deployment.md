# Deployment

## Images

This repo does not build images. It names them.

```
     built elsewhere                    here                  the cluster
  ┌────────────────────┐        ┌──────────────────┐      ┌──────────────┐
  │ site source repo   │  push  │ overlays/<env>/  │      │   kubelet    │
  │ docker build/push  │ ─────► │   newTag: 1.0.0  │ ───► │ pulls the tag│
  └────────────────────┘        └──────────────────┘      └──────────────┘
```

The registry is the handoff. Deploying a new version is a one-line edit to an
overlay's `newTag:` — never a rebuild. Nothing here requires Docker, which is
why a cluster node running containerd can deploy this repo perfectly well.

Published to private ECR in `us-east-1`, account `866409326838` — so the cluster
must be able to authenticate before any pod starts (see below):

| Image | Serves |
|---|---|
| `<acct>.dkr.ecr.<region>.amazonaws.com/website` | `/` (the employee site) |
| `<acct>.dkr.ecr.<region>.amazonaws.com/core` | `/api` |
| `<acct>.dkr.ecr.<region>.amazonaws.com/auth` | `/api/auth`, `/api/health` |

Check what tags exist before pinning one:

```sh
aws ecr describe-images --region us-east-1 \
  --repository-name employee-web \
  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[].imageTags' --output text
```

Each service serves its own base path, which is why the Ingress needs no rewrite
rules. The site is a Nuxt/Nitro Node server listening on 3000, not nginx serving
static files — the resource sizing in `deployment.yaml` follows from that.

### ECR pull credentials

The image name lives in `k8s/base/<site>/kustomization.yaml` and the tag in the
overlay. Both already point at ECR; the part that is **not** in this repo is how
a node proves it may pull. Pick one, by cluster:

**EKS — grant the node role, and drop the `registry-ecr` component.** Attach
`AmazonEC2ContainerRegistryReadOnly` to the node group's IAM role. The kubelet's
built-in ECR credential provider mints a token per pull, so nothing expires and
no Secret exists to go stale.

The pod spec *does* still declare `imagePullSecrets: [ecr-creds]`, and that is
harmless on EKS: a missing pull Secret only logs an event, and the node
credentials satisfy the pull regardless. Nothing needs removing from the
Deployment.

**k3s or any non-AWS cluster — a docker-registry Secret.** No ECR credential
provider exists there, so the credentials must be stored:

```sh
kubectl -n uat create secret docker-registry ecr-creds \
  --docker-server=866409326838.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region us-east-1)"
```

then reference it from the pod spec via `imagePullSecrets: [{name: ecr-creds}]`.

> **The token expires in 12 hours.** That command works now and fails tomorrow
> with `ImagePullBackOff` / `401 Unauthorized` — and only for pods that happen to
> restart, so it looks intermittent. On k3s the Secret has to be recreated on a
> schedule (a CronJob running the command above). This is the reason the EKS
> node-role route is preferred wherever it is available.

## Deploy

`ENV` selects the overlay and defaults to `prod`:

```sh
make render ENV=uat   # print the manifests; nothing touches the cluster
make diff   ENV=uat   # what would change against what is live
make deploy ENV=uat   # kubectl apply -k k8s/overlays/uat
```

`make deploy` prints pods, services and the Ingress when it finishes. Once the
load balancer is provisioned:

```sh
kubectl -n uat get ingress company-web \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# -> http://<hostname>/  http://<hostname>/api  http://<hostname>/api/health
```

> **`apply -k` is one shot.** The old `kubectl apply -f` sequence let you stage
> the NetworkPolicies separately, and the ingress policy is the one that can
> take the site down. Read [security.md](security.md#applying-the-networkpolicies)
> before the first deploy on a cluster that is already serving users.

## The ingress controller

Base sets **no** `ingressClassName`; the overlay's edge component does, and both
overlays currently choose `alb` (see [below](#ingress-nginx-instead)). The
section that follows covers the ingress-nginx alternative, which has to be
installed in the cluster. Either way an Ingress whose class has no controller is
accepted by the API server and then silently ignored — it just sits there with an
empty `ADDRESS`, which is the usual reason "the Ingress applied fine but nothing
works".

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer

kubectl -n ingress-nginx get svc ingress-nginx-controller
```

On EKS that Service provisions an AWS load balancer, and its `EXTERNAL-IP`
becomes the entry point: `http://<address>/` and `http://<address>/api`.
To skip the load balancer cost while testing, install with
`--set controller.service.type=NodePort` and hit the node port directly.

No rewrite annotations are needed. Each image serves its files under the
matching subpath, so the path the browser requests is the path nginx looks up.

### ingress-nginx instead

The base sets **no class at all** and no controller annotations — it carries
routes and nothing about who serves them. The overlay names the edge, and both
overlays currently name **`alb`**, the AWS Load Balancer Controller, via
`components/aws`.

**An Ingress with no class, or a class no controller implements, does nothing.**
The API server accepts it and then silently ignores it: no routing, empty
`ADDRESS`, no error anywhere. So the component line is not optional decoration —
it is what makes the render deployable.

Pick exactly one edge component per overlay:

```yaml
# k8s/overlays/<env>/kustomization.yaml
components:
  - ../../components/aws              # ALB + NodePort + ECR pull credentials
```

On a self-managed cluster — kubeadm on EC2, k3s, kind — install the community
ingress-nginx controller (above) and name it instead. Images still come from
ECR there, so keep the registry component:

```yaml
components:
  - ../../components/registry-ecr     # ECR pull credentials
  - ../../components/ingress-nginx    # class nginx, Services stay ClusterIP
```

Path rules are untouched either way, so `/` and `/api` behave
identically. On EKS drop `registry-ecr` entirely — the node role supplies pull
credentials — and name
[`components/ingress-alb`](../k8s/components/ingress-alb/kustomization.yaml) alone.

| Component | Contributes |
|---|---|
| [`aws`](../k8s/components/aws/kustomization.yaml) | umbrella: `registry-ecr` + `ingress-alb` |
| [`ingress-alb`](../k8s/components/ingress-alb/kustomization.yaml) | `ingressClassName: alb`, ALB annotations, Services → NodePort |
| [`ingress-nginx`](../k8s/components/ingress-nginx/kustomization.yaml) | `ingressClassName: nginx`, Services stay ClusterIP |
| [`registry-ecr`](../k8s/components/registry-ecr/kustomization.yaml) | the ECR pull-secret refresh CronJob and its RBAC |

Two things decide whether the ALB path works at all:

**The controller and its IAM.** It needs an OIDC provider, IRSA, the
AWS-published IAM policy, and `kubernetes.io/role/elb=1` tags on the public
subnets or subnet auto-discovery fails. Straightforward on EKS; substantially
more work on kubeadm, which has no IRSA to draw credentials from.

**`target-type` has to match the CNI.** `components/ingress-alb` sets
`instance`, which is the correct choice here: this cluster runs **Calico**, an
overlay CNI whose pod addresses exist only inside the cluster, so the ALB cannot
address them. `instance` routes to a node port instead — which is why the same
component flips the Services to `NodePort`. Only switch to `ip` on the AWS VPC
CNI, where pod addresses are VPC-routable.

One behavioural difference: ALB has no default backend, so a request matching
no rule returns a bare 404 from the load balancer rather than nginx's default
backend.

## Check it without an Ingress

```sh
kubectl -n uat port-forward svc/employee-web 8081:80   # http://localhost:8081/employee
kubectl -n uat port-forward svc/user-web     8082:80   # http://localhost:8082/user
```

## Worker nodes only

Both Deployments carry a required `nodeAffinity` rejecting any node labelled
`node-role.kubernetes.io/control-plane` or `node-role.kubernetes.io/master`, and
declare no tolerations — so a pod that could only be placed on a control-plane
node stays `Pending` instead of landing there. It is set once, in
[`k8s/base/web/deployment.yaml`](../k8s/base/web/deployment.yaml).

On EKS this is a safety net rather than a fix: the control plane is AWS-managed
and never appears as a node, so every node in the cluster is already a worker.
It does the real work on kubeadm or self-managed clusters, where masters join
the cluster as nodes.

Confirm placement after deploying:

```sh
kubectl -n uat get pods -o wide
kubectl get nodes -L node-role.kubernetes.io/control-plane
```

If your workers carry a positive label instead (some clusters label them
`node-role.kubernetes.io/worker=`), a `nodeSelector` on that label is the
simpler equivalent — but it is not set by default, which is why the rule here
excludes control-plane labels rather than requiring a worker label.

## The two environments

`uat` and `prod` share one cluster and are separated by namespace — one named
`uat`, one named `prod`. Resource names are identical in both, deliberately,
since UAT is only worth testing against if it is shaped like prod; the
namespace is what keeps identical names from colliding. `ENV` names the overlay
and the namespace at once.

The overlays differ in exactly four fields:

|  | uat | prod |
|---|---|---|
| namespace | `uat` | `prod` |
| replicas | 1 | 2 |
| image tag | moves first | moves after UAT proves the tag |
| Ingress host | `uat.api.example.com` | `api.example.com` |

That last row is load-bearing, not cosmetic. A namespace is not a routing
boundary: both Ingresses reach the same controller, so if both claimed
`/` with no host, ingress-nginx would award the path to whichever
object was created first and send UAT traffic to prod, or the reverse. No error
is logged. Distinct hosts are what separate them.

`make envs` prints both, rendered, so you can see how far apart they have drifted.

**`ENV` picks the overlay and the namespace together.** Both live on one
cluster, so a wrong `ENV` does not fail — it quietly deploys into the other
environment's namespace. `make current ENV=<env>` shows what is really running
in one before you touch it.

### Promoting a build

Starts from a tag already published to the registry — promotion never builds.

```sh
# 1. uat
#    set newTag: 1.0.1 in k8s/overlays/uat/kustomization.yaml, commit
make deploy rollout ENV=uat
# ... verify ...

# 2. prod — the same tag, already tested
#    set newTag: 1.0.1 in k8s/overlays/prod/kustomization.yaml, commit
make diff ENV=prod                     # read it
make deploy rollout ENV=prod
```

The two overlays name the **same** tag, so prod runs the exact bytes UAT
proved. Rebuilding between the two would produce a different image under the
same name and throw away everything UAT told you.

`make envs` shows how far apart the environments have drifted.

### Adding a third environment

Copy an overlay; never copy manifests:

```sh
cp -r k8s/overlays/uat k8s/overlays/dev
```

If it shares a cluster with an existing environment, it also needs a
`namespace:` line (which renames the Namespace object and stamps every
resource) and a distinct Ingress host, or its path routing will collide with
the environment already there. CI renders and validates every directory under
`k8s/overlays/` automatically — no workflow change needed.
