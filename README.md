# Static sites on Kubernetes

Deployment manifests for two static sites — **employee** (internal portal) and
**user** (customer account page) — each an nginx image serving `index.html` +
`style.css`, deployed as its own Deployment + Service, with one Ingress
path-routing to both. Argo CD keeps the cluster matching this repo.

**This repo deploys images; it does not build them.** The site source lives
elsewhere and publishes to a registry; here you name a tag and the cluster pulls
it. Nothing in this repo needs Docker.

```
registry (private ECR, us-east-1)
  043309361013.dkr.ecr.us-east-1.amazonaws.com/employee-web:<tag>  ->  /employee
  043309361013.dkr.ecr.us-east-1.amazonaws.com/user-web:<tag>      ->  /user

k8s/
  base/
    web/        Deployment + Service, written once and shared
    employee/   name, image, probe path for the employee site
    user/       name, image, probe path for the user site
    namespace.yaml  ingress.yaml  networkpolicy-*.yaml
  overlays/
    uat/        namespace + tag + replicas + host for UAT
    prod/       namespace + tag + replicas + host for prod

argocd/       one Application per environment
docs/         deployment, security, Argo CD, EC2 testing
```

UAT and prod share **one cluster** and are separated by **namespace** — `uat`
and `prod`. Resource names are identical in both, which namespaces make safe,
so `ENV` alone picks the environment: it names both the overlay directory and
the namespace. The base sets no namespace at all; each overlay declares its
own, and kustomize uses that to stamp every resource *and* to rename
`base/namespace.yaml`'s Namespace object.

The overlays differ in exactly four things: namespace, image tag, replica
count, and **Ingress host** — that last one is not optional. Two hostless
Ingresses claiming `/employee` in the same cluster collide silently, and the
path goes to whichever was created first.

Each image serves its files under a matching subpath
(`/usr/share/nginx/html/employee/`), so the Ingress needs no rewrite rules and
relative links to `style.css` resolve correctly.

Only `k8s/overlays/*` is deployable. `k8s/base` renders images untagged on
purpose — a tag is a release decision, so it lives in an overlay.

## Quickstart

```sh
make envs                       # what each environment is pinned to
make render ENV=uat             # print exactly what would be applied
make diff   ENV=uat             # what would change in the live cluster
make deploy ENV=uat             # apply k8s/overlays/uat into namespace uat
make rollout ENV=uat            # wait for both Deployments
```

`make` with no target lists everything. `ENV` defaults to `prod` and is the only
variable you normally set.

> `ENV` is both the overlay and the namespace. One cluster holds both
> environments, so a wrong `ENV` deploys to the wrong namespace rather than
> failing — `make current ENV=<env>` shows what is actually running there.

## Reaching it

`prod` keeps a **hostless** Ingress rule and is therefore the catch-all: any
`Host` no other Ingress claims lands there, so it is reachable by bare node IP
with no DNS at all.

```
http://<node-ip>:<nodeport>/employee     -> prod
http://<node-ip>:<nodeport>/user         -> prod
```

`uat` is the only environment claiming a hostname, which is what separates the
two. Exactly one hostless Ingress per class is safe; two collide silently.

The overlays carry a **placeholder** host, deliberately — a node's public IP is
public and changes on restart, so it does not belong in git. Supply the real
one at deploy time:

```sh
make deploy ENV=uat HOST=uat.api.<node-ip>.nip.io
```

`nip.io` is a public wildcard DNS service: any name shaped
`<anything>.<ip>.nip.io` resolves to that IP, with nothing to register. Only
the client resolving the name talks to it — the cluster never does. A line in
your local `/etc/hosts` works equally well and involves no third party, but has
to be repeated on every machine you browse from.

`HOST` is applied after the manifests, for the same reason `app-config` and
`ecr-secret` are: it describes one machine, not the repo. So `make render` and
`make diff` show the placeholder, and Argo CD reverts it on its next sync. Put
a real domain in the overlay once there is one.

Find the port with:

```sh
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

## Shipping a change

Once a new tag has been published to the registry, deploying it is a one-line
edit. Set it in [`k8s/overlays/uat/`](k8s/overlays/uat/kustomization.yaml),
commit, and let UAT prove it:

```sh
make deploy rollout ENV=uat
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



kubectl -n uat get secret ecr-creds
kubectl -n uat rollout restart deploy/employee-web deploy/user-web
make rollout ENV=uat
kubectl -n uat get pods

Confirm, then fix:
kubectl -n prod get configmap                 # website-config will be absent
make app-config ENV=prod                      # creates it + restarts the deployments
kubectl -n prod get pods -w


## NodePort
kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec":{"type":"NodePort"}}'

## Create Token
kubeadm token create --print-join-command

### Before Running Code, make sure work node is ready. 
## Then install Calico:
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
kubectl get nodes -w
![alt text](image.png)


# 0. prerequisite: a cluster with at least one SCHEDULABLE node,
#    plus ingress-nginx installed. This is your current blocker.

make deploy     ENV=prod        # 1. creates the namespace, the CronJob, everything
make app-config ENV=prod        # 2. the website-config ConfigMap
make aws-creds  ENV=prod AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
make ecr-secret ENV=prod        # 4. mints ecr-creds by running the CronJob
make rollout    ENV=prod        # 5. wait for both Deployments



First check which pod CIDR the cluster was initialised with, because the CNI manifest must match:


kubectl -n kube-system get cm kubeadm-config -o yaml | grep -i podSubnet
Then install Calico:


kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
kubectl get nodes -w