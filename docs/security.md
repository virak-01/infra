# Security

## What the manifests apply

- **No service account token** — `automountServiceAccountToken: false` on both
  Deployments ([`k8s/base/web/deployment.yaml`](../k8s/base/web/deployment.yaml)).
  These pods never call the Kubernetes API, so a container compromise hands over
  no cluster credential.
- **Pod Security Standards** — every environment namespace enforces `baseline`
  (no privileged containers, hostNetwork, hostPath or host namespaces) and
  warns/audits against `restricted`. Enforcement moves to `restricted` once the
  images run as non-root.
- **No egress** ([`networkpolicy-egress.yaml`](../k8s/base/networkpolicy-egress.yaml))
  — chiefly to block `169.254.169.254`, the EC2 metadata endpoint that would
  otherwise hand a compromised container the node's IAM role credentials.
- **Ingress restricted to the controller**
  ([`networkpolicy-ingress.yaml`](../k8s/base/networkpolicy-ingress.yaml)) — so
  no other pod can reach the web pods directly.

## Applying the NetworkPolicies

The two policies carry very different risk, and **`kubectl apply -k` applies
both at once.**

`deny-all-egress` is always safe: it constrains outbound traffic only, so it
cannot affect inbound requests, kubelet probes, or NodePort access.

`web-allow-ingress` can take the site down:

- Direct NodePort access stops working — that traffic does not come from the
  ingress-nginx namespace. Only appropriate once the Ingress genuinely serves
  your users.
- Depending on the CNI, kubelet liveness/readiness probes may also be blocked,
  since they originate from the node rather than from a pod. If pods start
  failing readiness right after applying, that is the cause: uncomment the
  node-CIDR rule in the manifest and set it to your VPC subnet range.

Roll back with:

```sh
kubectl -n uat delete networkpolicy web-allow-ingress
```

On a cluster already serving users, stage it. Comment the policy out of
[`k8s/base/kustomization.yaml`](../k8s/base/kustomization.yaml):

```yaml
resources:
  - namespace.yaml
  - employee
  - user
  - ingress.yaml
  - networkpolicy-egress.yaml
  # - networkpolicy-ingress.yaml   <- last, once the Ingress serves users
```

Deploy the rest, confirm the Ingress is genuinely serving traffic, then
uncomment and deploy again, watching readiness as it lands:

```sh
make deploy && make rollout
# ... verify http://<ingress>/employee and /user ...
# uncomment the line, then:
make deploy
kubectl -n uat get pods -w
```

Under Argo CD this is handled for you: `web-allow-ingress` carries
`argocd.argoproj.io/sync-wave: "10"`, so it is applied last, after the
Deployments report healthy. See [argocd.md](argocd.md).

## Check your CNI enforces NetworkPolicy first

Flannel does not — it accepts NetworkPolicy objects and silently ignores them,
which is worse than having none, because it looks protected:

```sh
kubectl -n kube-system get pods | grep -E 'flannel|calico|cilium|aws-node'
```

Only Calico, Cilium and similar actually enforce these. On Flannel, install
Calico for policy enforcement, or treat the two policy files as documentation
of intent rather than active controls.

## Still outstanding

- **TLS** — everything is plaintext HTTP. cert-manager + Let's Encrypt now that
  traffic goes through ingress-nginx.
- **Non-root containers** — rebuild on `nginxinc/nginx-unprivileged` (port
  8080), then add `runAsNonRoot`, `readOnlyRootFilesystem`,
  `capabilities: drop: [ALL]` and `seccompProfile: RuntimeDefault` to
  [`k8s/base/web/deployment.yaml`](../k8s/base/web/deployment.yaml) — once, for
  both sites. Then flip the namespace to `enforce: restricted`.
- **Base image CVEs** — build from the `1.27-alpine` pin rather than the Debian
  `nginx:latest` fallback, pin by digest, and scan with `trivy image`.
- **Node port exposure** — scope the security group to the ingress controller's
  port instead of leaving 30000-32767 open.
