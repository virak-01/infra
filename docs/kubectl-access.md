# Getting kubectl to work — `company-kubeadm-prod`

Account `866409326838`, region `us-east-1`, Kubernetes `v1.31.14`, provisioned by
[`terraform/infra-kubeadm`](../terraform/infra-kubeadm).

The cluster has been healthy the whole time. Every failure below was in the
*path to* the cluster, not the cluster itself. That distinction matters, because
the error kubectl prints points at the wrong thing.

---

## The one error that misleads everyone

```
The connection to the server localhost:8080 was refused - did you specify the right host or port?
```

This almost never means the API server is down. It means **kubectl found no
kubeconfig at all** and fell back to a hardcoded default of
`http://localhost:8080` — the legacy insecure port that kubeadm has not opened
since Kubernetes 1.20.

kubectl looks for its config in this order, and stops at the first hit:

1. `--kubeconfig=<path>` flag
2. `$KUBECONFIG` environment variable
3. `$HOME/.kube/config`

If all three miss, you get `localhost:8080`. So treat that message as
**"kubectl has no credentials"**, never as "the cluster is broken". One command
tells them apart:

```sh
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes
```

If that works, the cluster is fine and you have a config-discovery problem.

---

## Why it failed for you — five separate causes

**1. There is no SSH key pair on these instances.**
`terraform.tfvars` sets `key_name = null`, so every node was launched without
one. No `.pem` can ever work — `Ubuntu.pem` and `virak.pem` are for the *other*
two accounts. Access here is **SSM Session Manager only**, by design.

**2. `kubectl` was not installed on your laptop.** `command -v kubectl` returned
nothing.

**3. There was no kubeconfig on your laptop.** No `~/.kube/` directory existed.

**4. On the control plane, `$HOME` does not always resolve to a user that has a
kubeconfig.** Both `/root/.kube/config` and `/home/ubuntu/.kube/config` exist and
are valid — but they are only found when `$HOME` points at that user.

> **The `sudo` trap:** `sudo kubectl get nodes` preserves the *calling* user's
> `$HOME`. So it looks for the caller's kubeconfig, not root's, and fails with
> `localhost:8080` even though `/root/.kube/config` is sitting right there.
> Use `sudo -i` (login shell, resets `$HOME` to `/root`) or `sudo -H`.

**5. Remote access had two more blockers stacked behind those.**

- `admin.conf` points at `https://10.40.9.70:6443` — a **private VPC address**,
  unroutable from the internet. Copying the file to your laptop unchanged gives
  you a connection timeout.
- Rewriting it to the public IP then fails TLS verification. The API server
  certificate's SANs are:

  ```
  DNS:kubernetes, DNS:kubernetes.default, ... IP:10.96.0.1, IP:10.40.9.70, IP:44.195.21.247
  ```

  `44.195.21.247` is a **stale public IP**. The control plane was stopped and
  restarted, AWS handed it a new address (`44.205.14.146`), and the certificate
  still names the old one. You would get:

  ```
  x509: certificate is valid for 10.96.0.1, 10.40.9.70, 44.195.21.247, not 44.205.14.146
  ```

---

## The working process flow

### Path A — from your laptop (recommended)

This is the path that is now set up. It needs no certificate changes and
survives the public IP changing again, because it never uses the public IP.

**One-time setup** (already done):

```sh
# 1. kubectl matching the cluster version
curl -sSL -o ~/.local/bin/kubectl \
  https://dl.k8s.io/release/v1.31.14/bin/linux/amd64/kubectl
chmod +x ~/.local/bin/kubectl

# 2. Pull admin.conf off the control plane over SSM (no SSH, no key pair)
CID=$(aws ssm send-command --instance-ids i-0f8f69c51ddf7562e \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["base64 -w0 /etc/kubernetes/admin.conf"]}' \
  --query Command.CommandId --output text)
sleep 5
mkdir -p ~/.kube
aws ssm get-command-invocation --command-id "$CID" \
  --instance-id i-0f8f69c51ddf7562e --query StandardOutputContent --output text \
  | tr -d '\n\r' | base64 -d > ~/.kube/config

# 3. Rewrite it for the tunnel:
#      server:          https://127.0.0.1:6443  (the tunnel's local end)
#      tls-server-name: kubernetes              (a DNS SAN the cert *does* have)
#    tls-server-name is the trick that makes TLS validate even though you are
#    connecting to 127.0.0.1, which is not in the certificate.
sed -i 's|^\( *\)server: https://10\.40\.9\.70:6443|\1server: https://127.0.0.1:6443\n\1tls-server-name: kubernetes|' ~/.kube/config
chmod 600 ~/.kube/config
```

`~/.kube/config` is a full **cluster-admin** credential — `kubectl auth can-i '*' '*'`
returns `yes`. Treat it like a private key: mode `600`, never committed.

**Every session** — open the tunnel, leave it running in its own terminal:

```sh
export AWS_PROFILE=<your-profile>   # or export the key pair
aws ssm start-session \
  --target i-0f8f69c51ddf7562e \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}'
```

Then, in any other terminal:

```sh
kubectl get nodes
```

Requires `session-manager-plugin` locally (already installed).

### Path B — on the control plane itself

```sh
aws ssm start-session --target i-0f8f69c51ddf7562e
sudo -i          # NOT plain `sudo kubectl` — see the sudo trap above
kubectl get nodes
```

A `/etc/profile.d/kubeconfig.sh` has been added that sets `KUBECONFIG`
automatically for any login shell: it prefers `$HOME/.kube/config` and falls
back to `/etc/kubernetes/admin.conf` when readable. That makes Path B work for
root and `ubuntu` without thinking about it.

---

## What was changed

| Where | Change |
|---|---|
| Laptop | Installed `kubectl` v1.31.14 to `~/.local/bin/kubectl` |
| Laptop | Created `~/.kube/config` (mode 600), pointed at `127.0.0.1:6443` with `tls-server-name: kubernetes` |
| Control plane | Added `/etc/profile.d/kubeconfig.sh` to auto-set `KUBECONFIG` for login shells |

Nothing in the cluster itself was modified. No certificates were regenerated.

---

## Still outstanding

**The ALB returns 503/504.** Tracked separately in [alb-ingress.md](alb-ingress.md): node `providerID` was unset (now fixed), and cross-node pod networking between the two workers is still broken.

**`cluster-autoscaler` is in CrashLoopBackOff** (50 restarts). Two independent
reasons, both infrastructure gaps rather than cluster problems:

1. The control-plane instance role is missing autoscaling permissions:
   ```
   AccessDenied: ... not authorized to perform: autoscaling:DescribeAutoScalingGroups
   ```
   It needs `autoscaling:Describe*`, `SetDesiredCapacity`,
   `TerminateInstanceInAutoScalingGroup`, plus `ec2:DescribeInstanceTypes` and
   `ec2:DescribeLaunchTemplateVersions`.
2. **The ASG it targets does not exist.** It is configured for
   `k8s-learning-workers`; `describe-auto-scaling-groups` returns nothing in this
   account. The workers are plain EC2 instances created by
   `terraform/infra-kubeadm`, not an Auto Scaling Group.

Fix both in Terraform rather than by hand — the role is Terraform-managed and a
console edit will be reverted on the next `apply`. Until there is a real ASG,
the honest option is to remove the autoscaler manifest.

**`worker-1` (`i-0d6445f5c28651d26`, `10.40.2.157`) is a stopped EC2 instance**,
which is why it shows `NotReady`. Start it or drain and delete the node.

**The API certificate still carries a stale public IP.** Path A avoids this
entirely, but if you ever want direct public access, do it in this order:

1. Allocate an **Elastic IP** and associate it with the control plane — otherwise
   the next stop/start invalidates the certificate again.
2. Add that EIP to `apiServer.certSANs` and regenerate:
   ```sh
   mv /etc/kubernetes/pki/apiserver.{crt,key} /root/backup/
   kubeadm init phase certs apiserver --config <kubeadm-config.yaml>
   # then restart the kube-apiserver static pod
   ```

**Security posture.** `terraform.tfvars` currently sets all three of
`ssh_allowed_cidrs`, `api_allowed_cidrs` and `nodeport_allowed_cidrs` to
`0.0.0.0/0`. The Kubernetes API on `6443` is reachable from the open internet —
verified from outside the VPC. Since Path A uses SSM, `api_allowed_cidrs` can be
closed entirely.

**Rotate the root access keys.** The keys used to debug this are AWS *root*
credentials, and they were pasted into a chat transcript. Root keys cannot be
scoped by IAM policy and should not exist at all: delete them in
IAM → Security credentials, and create a scoped IAM user or role instead.
