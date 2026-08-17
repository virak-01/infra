#!/usr/bin/env bash
# Show what each environment is pinned to. Touches no cluster.
#
# Reads every overlay rather than taking --env: the whole point is comparing them, so
# you can see how far uat has run ahead of prod before promoting.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "Usage: $(basename "$0")    # image tags and replica counts, per overlay"; }

parse_common_args "$@"
require_cmd kubectl

for overlay in "${REPO_ROOT}"/k8s/overlays/*/; do
  printf '%s%s%s\n' "$C_CYAN" "$(basename "$overlay")" "$C_OFF"

  # Pulled out of the rendered YAML rather than grepped from kustomization.yaml, so
  # what prints is what would actually be applied — including anything a component
  # or patch changed.
  kubectl kustomize "$overlay" \
    | grep -oE '^[[:space:]]*-?[[:space:]]*image:[[:space:]]*[^[:space:]]+|^  replicas: .*' \
    | sed 's/^ *-* *image: */  image    /; s/^  replicas: /  replicas /'
done
