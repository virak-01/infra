# Static sites on Kubernetes

Two static sites — **employee** (internal portal) and **user** (customer account
page) — each nothing but `index.html` + `style.css`, baked into an nginx image
and deployed as its own Deployment + Service, with one Ingress path-routing to
both. Argo CD keeps the cluster matching this repo.

```
apps/
  employee/   index.html  style.css  Dockerfile   ->  ranvirak/employee-web  ->  /employee
  user/       index.html  style.css  Dockerfile   ->  ranvirak/user-web      ->  /user

k8s/
  base/
    web/        Deployment + Service, written once and shared
    employee/   name, image, probe path for the employee site
    user/       name, image, probe path for the user site
    namespace.yaml  ingress.yaml  networkpolicy-*.yaml
  overlays/
    staging/    tag + replicas for the staging cluster
    prod/       tag + replicas for the prod cluster

argocd/       one Application per environment
docs/         deployment, security, Argo CD
```

Staging and prod are **separate clusters**, so both use the `company` namespace
and identical resource names — the kubectl context is what picks the
environment. The overlays differ only in image tag and replica count.

Each image serves its files under a matching subpath
(`/usr/share/nginx/html/employee/`), so the Ingress needs no rewrite rules and
relative links to `style.css` resolve correctly.

Only `k8s/overlays/*` is deployable. `k8s/base` renders images untagged on
purpose — a tag is a release decision, so it lives in an overlay.

## Quickstart

```sh
open apps/employee/index.html   # preview, no cluster needed

make build TAG=1.0.0            # build both images
make push  TAG=1.0.0            # push (needs a Read & Write Docker Hub token)

make envs                       # what each environment is pinned to
make render ENV=staging         # print exactly what would be applied
make diff   ENV=staging         # what would change in the live cluster
make deploy ENV=staging         # apply k8s/overlays/staging
```

`make` with no target lists everything. `ENV` defaults to `prod`; every other
variable is overridable too: `make build REGISTRY=myregistry TAG=1.0.1`.

> `ENV` selects the overlay, **not the cluster.** Since the two environments
> live on different clusters, run `kubectl config current-context` before any
> `deploy` or `diff`.

## Shipping a change

Edit the HTML/CSS, then build and push a **new** tag — reusing one leaves nodes
serving a stale cached layer:

```sh
make build push TAG=1.0.1
```

Set that tag in [`k8s/overlays/staging/`](k8s/overlays/staging/kustomization.yaml),
commit, and let staging prove it:

```sh
kubectl config use-context <staging>
make deploy rollout ENV=staging
```

Promote by setting the same tag in [`k8s/overlays/prod/`](k8s/overlays/prod/kustomization.yaml)
and committing. Argo CD syncs it, or apply it yourself with
`make deploy rollout ENV=prod`. `make envs` shows how far apart the two are.

## Docs

| Doc | Covers |
|---|---|
| [Deployment](docs/deployment.md) | building, ECR, installing ingress-nginx, ALB, port-forward checks, worker-node placement |
| [Security](docs/security.md) | Pod Security Standards, the two NetworkPolicies, the CNI caveat, what is still outstanding |
| [Argo CD](docs/argocd.md) | installing it, the Application, why sync is manual, sync waves |

## Requirements

`kubectl` (1.27+, for the built-in kustomize), `docker`, and a cluster with an
ingress controller. `kubeconform` is optional and only needed for `make validate`.
