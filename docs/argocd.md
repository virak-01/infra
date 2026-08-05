# Argo CD

Git stays the source of truth; the browser is for watching diffs, syncing and
rolling back.

## Install and register

Staging and prod are separate clusters, so each runs its own Argo CD and gets
its own Application. Run this once per cluster, with that cluster's context
active:

```sh
kubectl config use-context <staging>          # then repeat for <prod>

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

kubectl apply -f argocd/application-staging.yaml    # or -prod.yaml
```

| File | Application | Syncs |
|---|---|---|
| [`application-staging.yaml`](../argocd/application-staging.yaml) | `company-web-staging` | `k8s/overlays/staging` |
| [`application-prod.yaml`](../argocd/application-prod.yaml) | `company-web` | `k8s/overlays/prod` |

Both use `server: https://kubernetes.default.svc` — "the cluster I run in" — so
neither needs cluster registration or credentials. If you would rather run one
Argo CD managing both, register the remote cluster with
`argocd cluster add <context>` and put its API URL in that Application's
`destination.server`.

`argocd/` is deliberately outside the synced path — Argo CD does not manage its
own Applications here, so these files are applied once by hand. Re-apply
whenever they change.

Reach the UI without exposing it publicly — an internet-facing Argo CD is a
cluster takeover waiting to happen:

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080 — user "admin", password from:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## What it syncs

Each Application points at an overlay, never at `k8s/` or `k8s/base`. Argo CD
finds the `kustomization.yaml` and renders it — no plugin or config needed. The
base renders images untagged, which is why it is not a valid sync target.

A release is therefore a one-line change to an overlay's `images:` block, which
is also the whole diff Argo CD shows and the whole thing a rollback reverts.
Promoting staging to prod is that same line, copied between two overlays — so
the two Applications show independent diffs and prod never moves by accident.

## Sync is manual by design

Neither Application has an `automated:` block. Argo CD's job is making the
cluster match git, and git may describe something the cluster does not have yet
— for example the repo declares the Services as `ClusterIP`, so syncing removes
whatever NodePort is currently serving traffic. Manual sync means you see that
in the diff and decide, instead of finding out from a dead URL.

**Before the first sync, read the diff.** Either finish the ingress-nginx
install first, or capture the live Service into the repo so git matches reality:

```sh
kubectl -n company get svc employee-web -o yaml > /tmp/svc.yaml   # then fold into k8s/base/
```

Once the repo describes what is genuinely running, enable automation by
uncommenting the `automated:` block. **Turn it on for staging first** — that is
the environment whose whole job is finding out what auto-sync would do before
prod does. Leaving prod manual keeps promotion a decision rather than a
side effect of a merge.

## Sync waves

Argo CD applies a rendered manifest set in one shot, which would push the risky
ingress NetworkPolicy at the same time as everything else.
`k8s/base/networkpolicy-ingress.yaml` carries
`argocd.argoproj.io/sync-wave: "10"`, so it lands last — after the Deployments
are healthy — rather than simultaneously.

That ordering is an Argo CD feature only. A plain `kubectl apply -k` ignores
sync waves and applies everything together; see
[security.md](security.md#applying-the-networkpolicies).
