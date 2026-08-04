# Static sites on Kubernetes

Two static sites — **employee** (internal portal) and **user** (customer account
page) — each nothing but `index.html` + `style.css`, baked into an nginx image
and deployed as its own Deployment + Service, with one Ingress path-routing to
both.

```
employee/  index.html  style.css  Dockerfile   ->  ranvirak/employee-web:1.0.0  ->  /employee
user/      index.html  style.css  Dockerfile   ->  ranvirak/user-web:1.0.0      ->  /user
k8s/       namespace.yaml  employee.yaml  user.yaml  ingress.yaml
```

Each image serves its files under a matching subpath
(`/usr/share/nginx/html/employee/`), so the Ingress needs no rewrite rules and
relative links to `style.css` resolve correctly.

## Preview locally, no cluster

```sh
open employee/index.html
open user/index.html
```

## Build

The manifests pull from Docker Hub, so build under those names directly:

```sh
docker build -t ranvirak/employee-web:1.0.0 employee
docker build -t ranvirak/user-web:1.0.0 user
```

If the `nginx:1.27-alpine` base cannot be pulled on your network, build against a
base you already have cached — the committed pin stays untouched:

```sh
docker build --build-arg BASE=nginx:latest -t ranvirak/employee-web:1.0.0 employee
```

Push (needs a Docker Hub token with **Read & Write** scope — a read-only token
fails with `unauthorized: access token has insufficient scopes`):

```sh
docker login -u ranvirak
docker push ranvirak/employee-web:1.0.0
docker push ranvirak/user-web:1.0.0
```

For a private registry instead, retag and update the `image:` fields in
`k8s/employee.yaml` and `k8s/user.yaml`. For ECR:

```sh
ACCOUNT=123456789012
REGION=ap-southeast-1
REGISTRY=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $REGISTRY

aws ecr create-repository --repository-name employee-web --region $REGION
aws ecr create-repository --repository-name user-web --region $REGION

docker tag ranvirak/employee-web:1.0.0 $REGISTRY/employee-web:1.0.0
docker tag ranvirak/user-web:1.0.0     $REGISTRY/user-web:1.0.0
docker push $REGISTRY/employee-web:1.0.0
docker push $REGISTRY/user-web:1.0.0
```

## Deploy

```sh
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/employee.yaml -f k8s/user.yaml -f k8s/ingress.yaml

kubectl -n company get pods,svc,ingress
```

Once the load balancer is provisioned:

```sh
kubectl -n company get ingress company-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# -> http://<hostname>/employee   and   http://<hostname>/user
```

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

To use an AWS ALB instead, set `ingressClassName: alb` and add:

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

## Worker nodes only

Both Deployments carry a required `nodeAffinity` rejecting any node labelled
`node-role.kubernetes.io/control-plane` or `node-role.kubernetes.io/master`, and
declare no tolerations — so a pod that could only be placed on a control-plane
node stays `Pending` instead of landing there.

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

## Check it without an Ingress

```sh
kubectl -n company port-forward svc/employee-web 8081:80   # http://localhost:8081/employee
kubectl -n company port-forward svc/user-web     8082:80   # http://localhost:8082/user
```

## Security

Applied in the manifests:

- **No service account token** — `automountServiceAccountToken: false` on both
  Deployments. These pods never call the Kubernetes API, so a container
  compromise hands over no cluster credential.
- **Pod Security Standards** — the `company` namespace enforces `baseline`
  (no privileged containers, hostNetwork, hostPath or host namespaces) and
  warns/audits against `restricted`. Enforcement moves to `restricted` once the
  images run as non-root.
- **No egress** (`networkpolicy-egress.yaml`) — chiefly to block
  `169.254.169.254`, the EC2 metadata endpoint that would otherwise hand a
  compromised container the node's IAM role credentials.
- **Ingress restricted to the controller** (`networkpolicy-ingress.yaml`) — so
  no other pod can reach the web pods directly.

Apply in this order, verifying between the last two:

```sh
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/employee.yaml -f k8s/user.yaml
kubectl apply -f k8s/networkpolicy-egress.yaml     # always safe
kubectl apply -f k8s/networkpolicy-ingress.yaml    # only once the Ingress serves users
kubectl -n company get pods -w                     # watch readiness after that last one
```

**Check that your CNI enforces NetworkPolicy first.** Flannel does not — it
accepts NetworkPolicy objects and silently ignores them, which is worse than
having none, because it looks protected:

```sh
kubectl -n kube-system get pods | grep -E 'flannel|calico|cilium|aws-node'
```

Only Calico, Cilium and similar actually enforce these. On Flannel, install
Calico for policy enforcement, or treat the two policy files as documentation
of intent rather than active controls.

Still outstanding:

- **TLS** — everything is plaintext HTTP. cert-manager + Let's Encrypt now that
  traffic goes through ingress-nginx.
- **Non-root containers** — rebuild on `nginxinc/nginx-unprivileged` (port
  8080), then add `runAsNonRoot`, `readOnlyRootFilesystem`,
  `capabilities: drop: [ALL]` and `seccompProfile: RuntimeDefault`.
- **Base image CVEs** — build from the `1.27-alpine` pin rather than the Debian
  `nginx:latest` fallback, pin by digest, and scan with `trivy image`.
- **Node port exposure** — scope the security group to the ingress controller's
  port instead of leaving 30000-32767 open.

## Argo CD (optional)

Git stays the source of truth; the browser is for watching diffs, syncing and
rolling back. Install it, then register the Application:

```sh
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

kubectl apply -f argocd/application.yaml
```

Reach the UI without exposing it publicly — an internet-facing Argo CD is a
cluster takeover waiting to happen:

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080 — user "admin", password from:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

**Before the first sync, read the diff.** Sync is manual by design. The repo
declares the Services as `ClusterIP`, so syncing removes whatever NodePort is
currently serving traffic. Either finish the ingress-nginx install first, or
capture the live Service into the repo so git matches reality:

```sh
kubectl -n company get svc employee-web -o yaml > /tmp/svc.yaml   # then edit into k8s/
```

`k8s/networkpolicy-ingress.yaml` carries `argocd.argoproj.io/sync-wave: "10"`,
so it is applied last — after the Deployments are healthy — rather than
simultaneously with everything else.

Once the repo describes what is genuinely running, turn on automation by
uncommenting the `automated:` block in `argocd/application.yaml`.

## Update a page

Edit the HTML/CSS, then rebuild with a new tag and roll it out — avoid reusing a
tag, since nodes may keep the old cached layer:

```sh
docker build -t ranvirak/employee-web:1.0.1 employee && docker push ranvirak/employee-web:1.0.1
kubectl -n company set image deployment/employee-web nginx=ranvirak/employee-web:1.0.1
kubectl -n company rollout status deployment/employee-web
```
# bubernetes
