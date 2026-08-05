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

Currently published (public, no pull secret needed):

| Image | Serves |
|---|---|
| `ranvirak/employee-web` | `/employee` |
| `ranvirak/user-web` | `/user` |

Check what tags exist before pinning one:

```sh
curl -s https://hub.docker.com/v2/repositories/ranvirak/employee-web/tags/ \
  | tr ',' '\n' | grep '"name"'
```

Each image serves its files under a matching subpath
(`/usr/share/nginx/html/employee/`), which is why the Ingress needs no rewrite
rules and relative links to `style.css` resolve.

### Pulling from a private registry instead

Point the overlays at the new names — no Deployment manifest changes, which is
the point of the overlay. For ECR:

```yaml
# k8s/overlays/prod/kustomization.yaml
images:
  - name: ranvirak/employee-web
    newName: 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/employee-web
    newTag: 1.0.0
```

A private registry also needs pull credentials in the namespace:

```sh
kubectl -n company create secret docker-registry ecr-creds \
  --docker-server=123456789012.dkr.ecr.ap-southeast-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region ap-southeast-1)"
```

then reference it from the pod spec via `imagePullSecrets`. On EKS the better
answer is to skip the secret entirely and grant the **node role** ECR pull
permission (`AmazonEC2ContainerRegistryReadOnly`), since ECR tokens expire every
12 hours and a stored secret goes stale.

## Deploy

`ENV` selects the overlay and defaults to `prod`:

```sh
make render ENV=staging   # print the manifests; nothing touches the cluster
make diff   ENV=staging   # what would change against what is live
make deploy ENV=staging   # kubectl apply -k k8s/overlays/staging
```

`make deploy` prints pods, services and the Ingress when it finishes. Once the
load balancer is provisioned:

```sh
kubectl -n company get ingress company-web \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# -> http://<hostname>/employee   and   http://<hostname>/user
```

> **`apply -k` is one shot.** The old `kubectl apply -f` sequence let you stage
> the NetworkPolicies separately, and the ingress policy is the one that can
> take the site down. Read [security.md](security.md#applying-the-networkpolicies)
> before the first deploy on a cluster that is already serving users.

## The ingress controller

The Ingress targets the community **ingress-nginx** controller
(`ingressClassName: nginx`), which has to be installed in the cluster. An
Ingress whose class has no controller is accepted by the API server and then
silently ignored — it just sits there with an empty `ADDRESS`, which is the
usual reason "the Ingress applied fine but nothing works".

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer

kubectl -n ingress-nginx get svc ingress-nginx-controller
```

On EKS that Service provisions an AWS load balancer, and its `EXTERNAL-IP`
becomes the entry point: `http://<address>/employee` and `http://<address>/user`.
To skip the load balancer cost while testing, install with
`--set controller.service.type=NodePort` and hit the node port directly.

No rewrite annotations are needed. Each image serves its files under the
matching subpath, so the path the browser requests is the path nginx looks up.

### AWS ALB instead

Set `ingressClassName: alb` in [`k8s/base/ingress.yaml`](../k8s/base/ingress.yaml)
and add:

```yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
```

That route additionally needs the AWS Load Balancer Controller installed (OIDC
provider, IRSA, IAM policy) and `kubernetes.io/role/elb=1` tags on the public
subnets, or subnet auto-discovery fails.

## Check it without an Ingress

```sh
kubectl -n company port-forward svc/employee-web 8081:80   # http://localhost:8081/employee
kubectl -n company port-forward svc/user-web     8082:80   # http://localhost:8082/user
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
kubectl -n company get pods -o wide
kubectl get nodes -L node-role.kubernetes.io/control-plane
```

If your workers carry a positive label instead (some clusters label them
`node-role.kubernetes.io/worker=`), a `nodeSelector` on that label is the
simpler equivalent — but it is not set by default, which is why the rule here
excludes control-plane labels rather than requiring a worker label.

## The two environments

`staging` and `prod` are separate clusters. Both deploy into the `company`
namespace with identical resource names — deliberately, since staging is only
worth testing against if it is shaped like prod. The overlays differ in exactly
two fields:

|  | staging | prod |
|---|---|---|
| replicas | 1 | 2 |
| image tag | moves first | moves after staging proves the tag |

`make envs` prints both, rendered, so you can see how far apart they have drifted.

**`ENV` picks the overlay, not the cluster.** There is no binding between the
two — `make deploy ENV=prod` against a staging context deploys prod's manifests
to staging. Check first:

```sh
kubectl config current-context
```

### Promoting a build

Starts from a tag already published to the registry — promotion never builds.

```sh
# 1. staging
#    set newTag: 1.0.1 in k8s/overlays/staging/kustomization.yaml, commit
kubectl config use-context <staging>
make deploy rollout ENV=staging
# ... verify ...

# 2. prod — the same tag, already tested
#    set newTag: 1.0.1 in k8s/overlays/prod/kustomization.yaml, commit
kubectl config use-context <prod>
make diff ENV=prod                     # read it
make deploy rollout ENV=prod
```

The two overlays name the **same** tag, so prod runs the exact bytes staging
proved. Rebuilding between the two would produce a different image under the
same name and throw away everything staging told you.

`make envs` shows how far apart the environments have drifted.

### Adding a third environment

Copy an overlay; never copy manifests:

```sh
cp -r k8s/overlays/staging k8s/overlays/dev
```

If it shares a cluster with an existing environment, it also needs a
`namespace:` line (which renames the Namespace object and stamps every
resource) and a distinct Ingress host, or its path routing will collide with
the environment already there. CI renders and validates every directory under
`k8s/overlays/` automatically — no workflow change needed.
