# Static sites on Kubernetes

Deployment manifests for two static sites — **employee** (internal portal) and
**user** (customer account page) — each an nginx image serving `index.html` +
`style.css`, deployed as its own Deployment + Service, with one Ingress
path-routing to both. Argo CD keeps the cluster matching this repo.

**This repo deploys images; it does not build them.** The site source lives
elsewhere and publishes to a registry; here you name a tag and the cluster pulls
it. Nothing in this repo needs Docker.

```
registry (Docker Hub)
  ranvirak/employee-web:<tag>   ->  /employee
  ranvirak/user-web:<tag>       ->  /user

k8s/
  base/
    web/        Deployment + Service, written once and shared
    employee/   name, image, probe path for the employee site
    user/       name, image, probe path for the user site
    namespace.yaml  ingress.yaml  networkpolicy-*.yaml
  overlays/
    staging/    tag + replicas for the staging cluster
    prod/       tag + replicas for the prod cluster
    ec2-test/   throwaway single-node box — NOT for real use

argocd/       one Application per environment
docs/         deployment, security, Argo CD, EC2 testing
local/        kind config for a local learning cluster
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
make envs                       # what each environment is pinned to
make render ENV=staging         # print exactly what would be applied
make diff   ENV=staging         # what would change in the live cluster
make deploy ENV=staging         # apply k8s/overlays/staging
make rollout ENV=staging        # wait for both Deployments
```

`make` with no target lists everything. `ENV` defaults to `prod` and is the only
variable you normally set.

> `ENV` selects the overlay, **not the cluster.** Since the two environments
> live on different clusters, run `kubectl config current-context` before any
> `deploy` or `diff`.

## Shipping a change

Once a new tag has been published to the registry, deploying it is a one-line
edit. Set it in [`k8s/overlays/staging/`](k8s/overlays/staging/kustomization.yaml),
commit, and let staging prove it:

```sh
kubectl config use-context <staging>
make deploy rollout ENV=staging
```

Promote by setting the **same** tag in [`k8s/overlays/prod/`](k8s/overlays/prod/kustomization.yaml)
and committing. Argo CD syncs it, or apply it yourself with
`make deploy rollout ENV=prod`. `make envs` shows how far apart the two are.

Never reuse a tag. Nodes cache layers, so the same tag can mean two different
images across the fleet — and a rollback to it lands somewhere undefined. CI
fails any overlay that renders an untagged image, since that resolves to
`:latest`.

## Docs

| Doc | Covers |
|---|---|
| [Deployment](docs/deployment.md) | building, ECR, installing ingress-nginx, ALB, port-forward checks, worker-node placement |
| [Security](docs/security.md) | Pod Security Standards, the two NetworkPolicies, the CNI caveat, what is still outstanding |
| [Argo CD](docs/argocd.md) | installing it, the Application, why sync is manual, sync waves |
| [EC2 testing](docs/ec2-testing.md) | a throwaway k3s box: security groups, the single-node trap, and testing the egress policy against real instance metadata |

## Requirements

`kubectl` (1.27+, for the built-in kustomize), `docker`, and a cluster with an
ingress controller. `kubeconform` is optional and only needed for `make validate`.
