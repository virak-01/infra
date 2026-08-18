#!/usr/bin/env bash
# Worker bootstrap. Runs once from cloud-init user-data; safe to re-run.
#
# THE ORDERING PROBLEM this solves. Terraform creates the control plane and the
# workers at nearly the same moment, and `depends_on` only orders the API calls —
# it cannot wait for software inside an instance. So a worker reaches this point
# well before the control plane has finished `kubeadm init` and published a join
# command, and the SSM parameter it needs does not exist yet.
#
# Polling with a deadline is the fix. The alternative — failing fast — would make
# every apply require a manual join afterwards.
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-__K8S_MINOR__}"
JOIN_PARAM="${JOIN_PARAM:-__JOIN_PARAM__}"
AWS_REGION="${AWS_REGION:-__AWS_REGION__}"

# 20 minutes. A control plane normally takes 4-6 minutes from boot to a published
# token; this leaves room for a slow AMI or a retried CNI apply without waiting
# forever on a control plane that genuinely failed.
JOIN_WAIT_SECONDS="${JOIN_WAIT_SECONDS:-1200}"
JOIN_POLL_INTERVAL="${JOIN_POLL_INTERVAL:-15}"

LOG=/var/log/k8s-bootstrap.log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date -u +%FT%TZ)] worker: $*"; }

export K8S_MINOR
# shellcheck source=install-containerd.sh
source "$(dirname "${BASH_SOURCE[0]}")/install-containerd.sh"

configure_kernel
disable_swap
install_containerd
install_kubernetes

# ------------------------------------------------------------- idempotency gate
#
# kubelet.conf is written by a successful join and holds this node's client
# certificate. Its presence means the node is already a cluster member, and
# re-running `kubeadm join` would fail on the existing config — so skip out early
# rather than break a working node.

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  log "already joined, nothing to do"
  systemctl enable --now kubelet
  exit 0
fi

# -------------------------------------------------------- fetch the join command

log "waiting for ${JOIN_PARAM} (up to ${JOIN_WAIT_SECONDS}s)"

deadline=$((SECONDS + JOIN_WAIT_SECONDS))
JOIN_COMMAND=""

while ((SECONDS < deadline)); do
  # --with-decryption because the parameter is a SecureString. The worker role
  # grants kms:Decrypt only via SSM; see terraform/modules/iam.
  if JOIN_COMMAND=$(aws ssm get-parameter \
    --region "${AWS_REGION}" \
    --name "${JOIN_PARAM}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text 2>/dev/null); then

    # Terraform seeds the parameter with a placeholder so the resource can exist
    # before the control plane has anything real to put in it. Treat that as
    # "not ready" rather than as a value, or `kubeadm join PENDING` runs and fails.
    if [[ -n "$JOIN_COMMAND" && "$JOIN_COMMAND" != "PENDING" ]]; then
      log "join command retrieved"
      break
    fi
    log "parameter still holds the placeholder, waiting"
  else
    log "parameter not readable yet, waiting"
  fi

  JOIN_COMMAND=""
  sleep "${JOIN_POLL_INTERVAL}"
done

if [[ -z "$JOIN_COMMAND" ]]; then
  log "ERROR: no join command after ${JOIN_WAIT_SECONDS}s."
  log "  Check the control plane:  sudo tail -50 /var/log/k8s-bootstrap.log"
  log "  Then join manually:       scripts/join-worker.sh"
  exit 1
fi

# ------------------------------------------------------------------ kubeadm join
#
# The command is never echoed. It contains a live bootstrap token, and this script
# tees its output to a log file that other tooling may collect.

log "joining the cluster"

# --ignore-preflight-errors is deliberately NOT used. A preflight failure here means
# swap is on, a port is occupied, or the runtime is misconfigured — all of which
# produce a node that joins and then misbehaves in ways that are much harder to
# diagnose than a refused join.
if bash -c "${JOIN_COMMAND}"; then
  log "joined"
else
  log "ERROR: kubeadm join failed. Common causes:"
  log "  * token expired      — mint a new one with scripts/join-worker.sh"
  log "  * 6443 unreachable   — check the control-plane security group"
  log "  * clock skew         — token validation is time-sensitive"
  exit 1
fi

systemctl enable --now kubelet

log "worker ready. Confirm from the control plane with: kubectl get nodes"
