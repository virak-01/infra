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

main() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
  fi

  configure_kernel
  disable_swap
  install_containerd
  install_kubernetes

  log "node prerequisites ready"
}

# Only run when executed directly, so control-plane.sh and worker.sh can source
# this file for its functions without triggering main().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
