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

## Update a page

Edit the HTML/CSS, then rebuild with a new tag and roll it out — avoid reusing a
tag, since nodes may keep the old cached layer:

```sh
docker build -t ranvirak/employee-web:1.0.1 employee && docker push ranvirak/employee-web:1.0.1
kubectl -n company set image deployment/employee-web nginx=ranvirak/employee-web:1.0.1
kubectl -n company rollout status deployment/employee-web
```
# bubernetes
