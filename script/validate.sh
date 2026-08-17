#!/usr/bin/env bash
# Render and check against the Kubernetes API schema. What CI runs. Touches no cluster.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env <name>] [--all]

  --all   validate every overlay, not just one

-strict rejects unknown fields, which is what catches a typo'd key that the API
server would otherwise silently drop.
EOF
}

parse_common_args "$@"
eval "set -- ${REST_ARGS}"

ALL=false
[ "${1:-}" = "--all" ] && ALL=true

require_cmd kubectl
require_cmd kubeconform "brew install kubeconform"

validate_one() {
  local overlay="$1"
  printf '%s%s%s\n' "$C_CYAN" "$(basename "$overlay")" "$C_OFF"
  kubectl kustomize "$overlay" | kubeconform -strict -summary -
}

if [ "$ALL" = true ]; then
  status=0
  for overlay in "${REPO_ROOT}"/k8s/overlays/*/; do
    validate_one "$overlay" || status=1
  done
  exit $status
else
  resolve_env
  validate_one "$OVERLAY"
fi
