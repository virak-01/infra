# Static sites on Kubernetes

Two static sites — **employee** (internal portal) and **user** (customer account
page) — each nothing but `index.html` + `style.css`, baked into an nginx image
and deployed as its own Deployment + Service, with one Ingress path-routing to
both.

```
employee/  index.html  style.css  Dockerfile   ->  employee-web:1.0.0  ->  /employee
user/      index.html  style.css  Dockerfile   ->  user-web:1.0.0      ->  /user
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

```sh
docker build -t employee-web:1.0.0 employee
docker build -t user-web:1.0.0 user
```

Push to a registry your cluster can pull from and update the `image:` fields in
`k8s/employee.yaml` and `k8s/user.yaml`. For ECR:

```sh
ACCOUNT=123456789012
REGION=ap-southeast-1
REGISTRY=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $REGISTRY

aws ecr create-repository --repository-name employee-web --region $REGION
aws ecr create-repository --repository-name user-web --region $REGION

docker tag employee-web:1.0.0 $REGISTRY/employee-web:1.0.0
docker tag user-web:1.0.0     $REGISTRY/user-web:1.0.0
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

The Ingress assumes the AWS Load Balancer Controller (`ingressClassName: alb`).
On a cluster running nginx-ingress instead, set `ingressClassName: nginx` and
delete the `alb.ingress.kubernetes.io/*` annotations.

## Check it without an Ingress

```sh
kubectl -n company port-forward svc/employee-web 8081:80   # http://localhost:8081/employee
kubectl -n company port-forward svc/user-web     8082:80   # http://localhost:8082/user
```

## Update a page

Edit the HTML/CSS, then rebuild with a new tag and roll it out — avoid reusing a
tag, since nodes may keep the old cached layer:

```sh
docker build -t $REGISTRY/employee-web:1.0.1 employee && docker push $REGISTRY/employee-web:1.0.1
kubectl -n company set image deployment/employee-web nginx=$REGISTRY/employee-web:1.0.1
kubectl -n company rollout status deployment/employee-web
```
# bubernetes
