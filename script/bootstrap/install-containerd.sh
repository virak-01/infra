#!/usr/bin/env bash
# Container runtime and Kubernetes packages. Sourced by control-plane.sh and
# worker.sh, and safe to run on its own.
#
# IDEMPOTENT: every step checks its own result first, so re-running on a live node
# neither reinstalls packages nor restarts a working runtime. That matters because
# these scripts run from cloud-init, and a failed boot is usually retried by hand
# on a node that is already half configured.
#
# Assumes Ubuntu 22.04 (Jammy). The package repositories below are Debian-family
# and the sysctl/module paths are systemd's; Amazon Linux would need different
# repositories and is deliberately not supported here.
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-1.31}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# --------------------------------------------------------------- kernel prereqs
#
# Two kernel modules and three sysctls, and all of them are load-bearing:
#
#   overlay + br_netfilter  containerd's overlayfs snapshotter, and bridged packet
#                           filtering that lets iptables see pod traffic.
#   bridge-nf-call-iptables Without it kube-proxy writes rules that never match and
#                           Service ClusterIPs silently blackhole.
#   ip_forward              Without it traffic never leaves the pod bridge, so
#                           cross-node pod traffic fails while same-node works —
#                           which reads as an intermittent application bug.

configure_kernel() {
  log "configuring kernel modules and sysctls"

  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

  # `|| true`: already-loaded is not an error, and the script runs under `set -e`.
  modprobe overlay || true
  modprobe br_netfilter || true

  cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

  sysctl --system >/dev/null
}

# ------------------------------------------------------------------------- swap
#
# The kubelet refuses to start with swap enabled unless explicitly configured to
# tolerate it. Both steps are needed: swapoff for now, fstab for after a reboot.

disable_swap() {
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    log "disabling swap"
    swapoff -a
  fi
  sed -i.bak -E '/\sswap\s/s/^(\s*)/\1#/' /etc/fstab
}

# -------------------------------------------------------------------- containerd

install_containerd() {
  if command -v containerd >/dev/null 2>&1; then
    log "containerd already installed, skipping"
  else
    log "installing containerd"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq apt-transport-https ca-certificates curl gnupg
    apt-get install -y -qq containerd
  fi

  # SystemdCgroup=true is THE most common kubeadm misconfiguration. The kubelet
  # uses the systemd cgroup driver by default; if containerd uses cgroupfs the two
  # disagree about resource accounting and the kubelet crash-loops with a message
  # about the cgroup driver that is easy to miss in the noise.
  if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
    log "writing containerd config with SystemdCgroup=true"
    mkdir -p /etc/containerd
    containerd config default >/etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl restart containerd
  else
    log "containerd already configured for systemd cgroups"
  fi

  systemctl enable --now containerd
}

# ------------------------------------------------------- kubeadm kubelet kubectl

install_kubernetes() {
  # KUBEADM'S PREFLIGHT NEEDS THESE AND NOTHING PULLS THEM IN. The kubelet package on
  # pkgs.k8s.io declares no dependency on conntrack, and Ubuntu's cloud image does not
  # ship it, so every package here installs cleanly and then `kubeadm init` refuses:
  #
  #   [ERROR FileExisting-conntrack]: conntrack not found in system path
  #
  # That is a fatal preflight error, not a warning, and it fails `join` for the same
  # reason it fails `init` — kube-proxy needs conntrack on every node. The bootstrap
  # unit then retries once a minute forever against a condition that cannot resolve
  # itself, which looks exactly like a cluster that is merely slow to form.
  #
  # DELIBERATELY OUTSIDE the kubeadm gate below. A node that already has kubeadm but is
  # missing these would skip the entire block and fail preflight again on every retry —
  # which is precisely the state a node reaches after this bug bites once.
  #
  # `command -v` rather than a dpkg query on purpose: preflight looks these up on PATH,
  # so this checks the same thing kubeadm is about to check.
  local missing=()
  local pkg
  for pkg in conntrack socat ethtool; do
    command -v "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done

  if ((${#missing[@]})); then
    log "installing kubeadm prerequisites: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}"
  fi

  if command -v kubeadm >/dev/null 2>&1; then
    log "kubeadm already installed ($(kubeadm version -o short 2>/dev/null || echo unknown)), skipping"
  else
    log "installing kubernetes ${K8S_MINOR} packages"
    export DEBIAN_FRONTEND=noninteractive

    install -m 0755 -d /etc/apt/keyrings

    # THE MINOR VERSION IS PART OF THE REPOSITORY URL. pkgs.k8s.io publishes one
    # repository per minor, so upgrading 1.31 -> 1.32 means changing this URL, not
    # just the pinned package version.
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" |
      gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
      >/etc/apt/sources.list.d/kubernetes.list

    apt-get update -qq
    apt-get install -y -qq kubelet kubeadm kubectl
  fi

  # Held so an unrelated `apt-get upgrade` cannot move the cluster a minor version
  # while it is running. Kubernetes upgrades are a deliberate, ordered procedure —
  # control plane first, one minor at a time — not a side effect of patching.
  apt-mark hold kubelet kubeadm kubectl >/dev/null

  systemctl enable kubelet
}

# ------------------------------------------------------------------ provider ID
#
# WHY THIS EXISTS. Kubernetes does not know it is running on AWS. On EKS the cloud
# provider fills in each Node's spec.providerID — the field that maps a node to its
# EC2 instance — but kubeadm ships no cloud provider, so the field stays empty and
# nothing complains until something needs that mapping.
#
# The AWS Load Balancer Controller needs it. With `target-type: instance` it has to
# translate "node ip-10-40-24-143" into "instance i-093bd099366a37797", and
# providerID is the ONLY field it will use. Empty means it can name no instance, so
# every TargetGroupBinding reconcile fails with
#
#   providerID is not specified for node: <name>
#
# the target groups stay empty, and the ALB answers 503 on every path. Worse, the
# controller aborts the whole reconcile at the FIRST node missing the field, so one
# unconfigured node keeps the entire ingress down. See docs/alb-ingress.md.
#
# THIS MUST RUN BEFORE THE NODE REGISTERS. spec.providerID is immutable once the
# Node object exists — setting it afterwards is refused by the API server, and the
# only remedy is to drain, delete and rejoin the node. So it is called before
# `kubeadm init` and `kubeadm join`, never after.
#
# /etc/default/kubelet is the documented seam. kubeadm's own drop-in at
# /etc/systemd/system/kubelet.service.d/10-kubeadm.conf carries
# `EnvironmentFile=-/etc/default/kubelet` and passes $KUBELET_EXTRA_ARGS through to
# the kubelet, so a flag placed here survives kubeadm regenerating its own config.
# Nothing else in this repo writes that file; the bootstrap owns it.
configure_provider_id() {
  local token az iid provider_id

  # IMDSv1 is disabled on these instances, so the token is mandatory, not optional.
  if ! token=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300"); then
    log "ERROR: no IMDSv2 token. Not an EC2 instance, or IMDS is blocked."
    return 1
  fi

  az=$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    http://169.254.169.254/latest/meta-data/placement/availability-zone || echo "")
  iid=$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    http://169.254.169.254/latest/meta-data/instance-id || echo "")

  if [[ -z "$az" || -z "$iid" ]]; then
    log "ERROR: IMDS returned no availability-zone or instance-id"
    return 1
  fi

  # THREE slashes. The empty segment between the second and third is where a region
  # would go and is intentionally blank — `aws://<az>/<id>` with two is not a valid
  # providerID and the kubelet will register with a malformed value.
  provider_id="aws:///${az}/${iid}"

  if [[ -f /etc/default/kubelet ]] && grep -qF -- "--provider-id=${provider_id}" /etc/default/kubelet; then
    log "provider-id already set to ${provider_id}"
  else
    log "setting kubelet provider-id to ${provider_id}"
    printf 'KUBELET_EXTRA_ARGS=--provider-id=%s\n' "${provider_id}" >/etc/default/kubelet
    chmod 0644 /etc/default/kubelet
    systemctl daemon-reload
  fi

  # A node that has already joined keeps whatever providerID it registered with,
  # because the field is immutable. Say so plainly rather than let the flag above
  # imply a fix that did not happen.
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    log "NOTE: this node has already joined. spec.providerID cannot be changed on an"
    log "  existing Node object — the flag applies only to a fresh registration."
    log "  Check the live value with:"
    log "    kubectl get node $(hostname) -o jsonpath='{.spec.providerID}'"
  fi
}

main() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
  fi

  configure_kernel
  disable_swap
  install_containerd
  install_kubernetes
  configure_provider_id

  log "node prerequisites ready"
}

# Only run when executed directly, so control-plane.sh and worker.sh can source
# this file for its functions without triggering main().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
