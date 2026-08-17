#!/usr/bin/env bash
# Apply k8s/cluster/<CLOUD> add-ons — ONE SET PER CLUSTER, not per environment.
#
# Not part of any overlay, and deliberately not under k8s/base: everything there is
# rendered by both overlays, which would stamp `namespace: prod` and `namespace: uat`
# onto a controller that must exist exactly once. Two Cluster Autoscalers would drive
# the same ASG in opposite directions.
#
# ENV is therefore ignored here. These manifests are byte-identical whichever
# environment you deploy, so re-applying from a uat deploy is a no-op rather than a
# conflict — which is what makes it safe for deploy.sh to call.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--cloud <name>]

Applies k8s/cluster/<cloud>. Available: $(ls "${REPO_ROOT}/k8s/cluster" | tr '\n' ' ')

A missing directory is NOT an error — see the note in the source.
EOF
}

parse_common_args "$@"
require_cmd kubectl

CLUSTER_ADDONS="${REPO_ROOT}/k8s/cluster/${CLOUD}"

# A MISSING DIRECTORY IS NOT AN ERROR. deploy.sh calls this, so a hard failure would
# block every deploy on a cloud whose add-on set nobody has written yet — and the
# workloads do not need it. It skips loudly instead.
if [ ! -d "$CLUSTER_ADDONS" ]; then
  note "no cluster add-ons for CLOUD=${CLOUD} (k8s/cluster/${CLOUD} does not exist) — skipping"
  info "  clouds with add-ons: $(ls "${REPO_ROOT}/k8s/cluster" | tr '\n' ' ')"
  exit 0
fi

show_context
kubectl apply -k "$CLUSTER_ADDONS"
echo

# Confirm what landed by asking the cluster about the objects the render declares,
# rather than hardcoding a Deployment name — that stays correct as add-ons are added.
kubectl kustomize "$CLUSTER_ADDONS" \
  | kubectl get -f - -o name --ignore-not-found 2>/dev/null \
  | grep '^deployment' \
  | xargs -r kubectl -n kube-system get || true
