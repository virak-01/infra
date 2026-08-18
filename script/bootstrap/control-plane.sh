#!/usr/bin/env bash
# Control-plane bootstrap. Runs once from cloud-init user-data; safe to re-run.
#
# Terraform renders this file as user-data, substituting the placeholders below.
# Run by hand with those values as environment variables instead.
#
# THE JOIN TOKEN IS NEVER WRITTEN TO GIT OR TO USER-DATA. It is minted here, on the
# node, after the control plane exists — and pushed to SSM Parameter Store as a
# SecureString that only the worker role may read. See terraform/modules/iam.
set -euo pipefail

# Rendered by Terraform (templatefile). Defaults let the script run standalone.
K8S_MINOR="${K8S_MINOR:-__K8S_MINOR__}"
POD_CIDR="${POD_CIDR:-__POD_CIDR__}"
JOIN_PARAM="${JOIN_PARAM:-__JOIN_PARAM__}"
AWS_REGION="${AWS_REGION:-__AWS_REGION__}"
CNI_MANIFEST_URL="${CNI_MANIFEST_URL:-__CNI_MANIFEST_URL__}"
TOKEN_TTL="${TOKEN_TTL:-24h}"
NODE_USER="${NODE_USER:-ubuntu}"

# GUARD: A PLACEHOLDER HERE MEANS THIS IS THE GIT COPY, RUN DIRECTLY.
#
# Terraform substitutes these at render time; the copy in the repository still holds
# the __NAME__ form. Without this check the script gets three minutes in — installing
# containerd, changing sysctls, disabling swap — before the apt URL for version
# "__K8S_MINOR__" returns 403 and set -e aborts. On the wrong machine that is a
# half-configured host and a confusing error a long way from its cause.
#
# Checked here rather than in install-containerd.sh, which has a real default for
# K8S_MINOR and is legitimately runnable on its own.
for _v in K8S_MINOR POD_CIDR JOIN_PARAM AWS_REGION CNI_MANIFEST_URL; do
  if [[ "${!_v}" == __*__ ]]; then
    echo "ERROR: ${_v} is unsubstituted (${!_v})." >&2

    # The two causes look identical from inside the script and have different fixes,
    # so tell them apart by whether this machine was ever rendered by Terraform.
    if [[ -f /etc/profile.d/k8s-bootstrap-env.sh ]]; then
      cat >&2 <<'EOF'

  This machine HAS the values — they are in /etc/profile.d/k8s-bootstrap-env.sh.
  Plain `sudo` discards the environment and never sources /etc/profile.d, so the
  defaults above stayed in place. Use a login shell:

      sudo -i
      /opt/k8s-bootstrap/control-plane.sh
EOF
    else
      cat >&2 <<'EOF'

  No /etc/profile.d/k8s-bootstrap-env.sh here, so this machine is not a node
  Terraform built — you are on the wrong host. This script installs containerd
  and kubeadm and will make an ops box look like a cluster node.
EOF
    fi
    exit 1
  fi
done

LOG=/var/log/k8s-bootstrap.log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date -u +%FT%TZ)] control-plane: $*"; }

export K8S_MINOR
# shellcheck source=install-containerd.sh
source "$(dirname "${BASH_SOURCE[0]}")/install-containerd.sh"

configure_kernel
disable_swap
install_containerd
install_kubernetes

# --------------------------------------------------------------- kubeadm init
#
# IDEMPOTENCY GATE. admin.conf exists only after a successful init, so its presence
# means this node is already a control plane. Re-running `kubeadm init` on a live
# node fails partway and can leave etcd unusable, so the check is not a nicety.

if [[ -f /etc/kubernetes/admin.conf ]]; then
  log "already initialised, skipping kubeadm init"
else
  log "initialising control plane, pod CIDR ${POD_CIDR}"

  # --apiserver-advertise-address is the PRIVATE IP. Nodes talk to the API server
  # over the VPC, and advertising the public address would route intra-cluster
  # traffic out through the internet gateway and back.
  #
  # The public IP still needs to be in the certificate SANs so kubectl works from
  # outside; --apiserver-cert-extra-sans covers that. Retrieved via IMDSv2, which
  # requires a token — IMDSv1 is disabled on these instances.
  IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  PRIVATE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    http://169.254.169.254/latest/meta-data/local-ipv4)
  PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")

  SANS="${PRIVATE_IP}"
  [[ -n "$PUBLIC_IP" ]] && SANS="${SANS},${PUBLIC_IP}"
  log "advertise ${PRIVATE_IP}, cert SANs ${SANS}"

  kubeadm init \
    --pod-network-cidr="${POD_CIDR}" \
    --apiserver-advertise-address="${PRIVATE_IP}" \
    --apiserver-cert-extra-sans="${SANS}" \
    --kubernetes-version="stable-${K8S_MINOR}"
fi

# ------------------------------------------------------------------- kubeconfig

log "configuring kubeconfig for root and ${NODE_USER}"

mkdir -p /root/.kube
install -m 600 /etc/kubernetes/admin.conf /root/.kube/config

# The unprivileged login user gets a copy so `kubectl` works after plain SSH.
# Mode 600 and owned by that user: admin.conf is a cluster-admin credential, and a
# world-readable copy hands the cluster to every process on the node.
if id -u "$NODE_USER" >/dev/null 2>&1; then
  NODE_HOME=$(getent passwd "$NODE_USER" | cut -d: -f6)
  mkdir -p "${NODE_HOME}/.kube"
  install -m 600 -o "$NODE_USER" -g "$NODE_USER" /etc/kubernetes/admin.conf "${NODE_HOME}/.kube/config"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

# -------------------------------------------------------------------------- CNI
#
# Until a CNI is installed every node stays NotReady and CoreDNS stays Pending.
# That is the single most common "the cluster is broken" report, and it is the
# expected state between `kubeadm init` and this step.

if kubectl get daemonset -A 2>/dev/null | grep -Eq 'calico|flannel|cilium|weave'; then
  log "CNI already present, skipping"
else
  log "installing CNI from ${CNI_MANIFEST_URL}"

  # Retried: the API server may still be settling immediately after init, and a
  # single apply that races it fails the whole bootstrap.
  for attempt in 1 2 3 4 5; do
    if kubectl apply -f "${CNI_MANIFEST_URL}"; then
      break
    fi
    log "CNI apply failed (attempt ${attempt}), retrying in 15s"
    sleep 15
  done
fi

# ----------------------------------------------------------- publish join command
#
# Minted fresh on every run rather than reused. `kubeadm token create` with a TTL
# means a leaked parameter stops working: after TOKEN_TTL the token is refused and
# a new worker needs a new one:  kubeadm token create --print-join-command
#
# --print-join-command emits the token AND the CA certificate hash. The hash is what
# lets a joining node verify the API server it is trusting, so a join command
# without it is vulnerable to a man-in-the-middle on first contact.

log "minting join command, ttl ${TOKEN_TTL}"
JOIN_COMMAND=$(kubeadm token create --ttl "${TOKEN_TTL}" --print-join-command)

log "publishing to SSM ${JOIN_PARAM}"

# SecureString: encrypted at rest with the AWS-managed SSM key. --overwrite because
# this runs again on reboot and on any re-run, each time with a fresh token.
#
# The value is passed via a file rather than on the command line — an argument is
# visible in `ps` output to every user on the box for as long as the call takes.
UMASK_OLD=$(umask)
umask 077
TOKEN_FILE=$(mktemp)
printf '%s' "$JOIN_COMMAND" >"$TOKEN_FILE"
umask "$UMASK_OLD"

aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --name "${JOIN_PARAM}" \
  --type SecureString \
  --overwrite \
  --value "file://${TOKEN_FILE}" \
  --description "kubeadm join command. Rotated on every control-plane boot." \
  >/dev/null

shred -u "$TOKEN_FILE" 2>/dev/null || rm -f "$TOKEN_FILE"

# ----------------------------------------------------------------------- ready

log "waiting for the node to report Ready (up to 5 minutes)"
kubectl wait --for=condition=Ready node --all --timeout=300s || {
  log "WARNING: node not Ready yet. Check: kubectl get nodes; kubectl -n kube-system get pods"
}

log "control plane ready"
kubectl get nodes -o wide
