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
- **Non-root, unprivileged containers** —
  [`deployment.yaml`](../k8s/base/web/deployment.yaml) sets `runAsNonRoot`,
  numeric UID/GID 1001, `capabilities: drop: [ALL]`,
  `allowPrivilegeEscalation: false` and `seccompProfile: RuntimeDefault`.
  `readOnlyRootFilesystem` is the one piece missing — Nitro writes to a temp dir
  at runtime, so it needs an `emptyDir` at `/tmp` and a test, not a guess.
- **No egress** ([`networkpolicy-egress.yaml`](../k8s/base/networkpolicy-egress.yaml))
  — a `deny-all-egress` floor plus narrow allows, chiefly to block
  `169.254.169.254`, the EC2 metadata endpoint that would otherwise hand a
  compromised container the node's IAM role credentials.
- **No ingress** ([`networkpolicy-ingress.yaml`](../k8s/base/networkpolicy-ingress.yaml))
  — the same shape: a `deny-all-ingress` floor, then `app-allow-ingress` opening
  port 3000 to the ingress controller and to same-namespace peers.

  This was a real gap until recently. The file held a single allow naming
  `employee-web` and `user-web`, with no blanket deny — so `api-auth-web` and
  `api-core-web`, both deployed, were reachable on 3000 from any pod in any
  namespace in the cluster. **Naming pods in an allow does not restrict the ones
  you leave out.** Only the deny does, which is why both files now start with
  one.

## Applying the NetworkPolicies

The two policies carry very different risk, and **`kubectl apply -k` applies
both at once.**

`deny-all-egress` is always safe: it constrains outbound traffic only, so it
cannot affect inbound requests, kubelet probes, or NodePort access.

The ingress pair **can take the site down**, and the deny is the risky half:

- Direct NodePort access from outside the VPC stops working. That traffic
  matches neither the ingress-nginx namespace nor the node CIDR, which is the
  intent — but it means any bookmark pointing at `<node-ip>:<nodeport>` dies.
- **The node CIDR must be right.** With the ALB in `target-type: instance` mode
  every request and every health check arrives from a node address, matched only
  by the `ipBlock` rule that
  [`components/ingress-alb`](../k8s/components/ingress-alb/kustomization.yaml)
  appends. It defaults to `172.31.0.0/16`, the AWS default-VPC range. In a
  custom VPC that matches nothing, the target group goes unhealthy, and it reads
  as a broken app rather than a blocked one. Check first:

  ```sh
  kubectl get nodes -o wide          # the INTERNAL-IP column
  ```

- Depending on the CNI, kubelet liveness/readiness probes originate from the node
  too, so the same rule admits them. Pods failing readiness immediately after
  applying is the signature of a wrong CIDR.

Roll back with:

```sh
kubectl -n uat delete networkpolicy deny-all-ingress
```

Deleting the **deny** restores reachability while leaving the allows in place,
which is the fast, safe direction. Deleting the allow instead leaves the deny
enforcing and the site stays down.

On a cluster already serving users, stage it — comment the file out of
[`k8s/base/kustomization.yaml`](../k8s/base/kustomization.yaml):

```yaml
resources:
  - namespace.yaml
  - ingress.yaml
  - networkpolicy-egress.yaml
  # - networkpolicy-ingress.yaml   <- last, once the Ingress serves users
```

Deploy the rest, confirm the Ingress is genuinely serving traffic, then
uncomment and deploy again, watching readiness as it lands:

```sh
make deploy && make rollout
# ... verify the served paths: / /api /api/auth /api/health ...
# uncomment the line, then:
make deploy
kubectl -n uat get pods -w
```

Under Argo CD this is handled for you: both policies carry
`argocd.argoproj.io/sync-wave: "10"`, so they are applied last, after the
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

- **TLS is configured but unreachable in prod.** The ALB holds an ACM
  certificate and `ssl-redirect: '443'` forces HTTPS, but the prod host patch is
  commented out in
  [`overlays/prod`](../k8s/overlays/prod/kustomization.yaml), so prod is a
  hostless catch-all. Every HTTPS request to the ALB's own hostname is therefore
  redirected and then fails certificate-name validation in the browser. Prod is
  not properly TLS-served until those hosts are uncommented and Route 53 ALIAS
  records point at the ALB. UAT already claims real hostnames and is fine.
- **`readOnlyRootFilesystem`** — the last piece of `restricted` the pods do not
  satisfy. Nitro writes to a temp dir at runtime, so this needs an `emptyDir`
  mounted at `/tmp` and a test. Once it lands, flip the namespace from
  `enforce: baseline` to `enforce: restricted` — everything else `restricted`
  requires is already set.
- **Long-lived ECR credential** — the refresh job authenticates with a static
  IAM user access key ([`registry-ecr`](../k8s/components/registry-ecr/ecr-credentials.yaml)),
  stored as a Kubernetes Secret and never rotated. Secrets are base64, not
  encrypted, unless etcd encryption-at-rest is enabled — which it is not here.
  On EKS this whole component disappears; on kubeadm, enable an
  `EncryptionConfiguration` and rotate the key on a schedule.
- **Base image CVEs** — pin by digest and scan with `trivy image` in CI. Nothing
  currently gates a vulnerable image from reaching prod.
- **Node port exposure** — scope the security group to the ingress controller's
  port instead of leaving 30000-32767 open. The `deny-all-ingress` policy now
  limits what a reachable node port can actually talk to, but the ports are
  still open at the network edge.
- **No etcd backup** — unrelated to policy, and the largest single risk in the
  setup: a kubeadm control plane with no snapshot schedule means losing that
  instance loses the cluster.

Two items previously listed here are **done** and were removed rather than left
to mislead: the containers do run as non-root with `drop: [ALL]` and
`RuntimeDefault` (see the list at the top of this file), and the plaintext-HTTP
note predates the ALB certificate — the remaining gap is the missing prod
hostname described above, not the absence of TLS.
