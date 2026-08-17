#!/usr/bin/env bash
# Print the manifests this repo would apply. Touches no cluster.
#
# The fastest way to check a change before it reaches anything: the render is exactly
# what `deploy.sh` pipes into kubectl.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env <name>]

Prints the rendered overlay to stdout. Pipe it wherever you like:

  $(basename "$0") --env uat | grep image:
  $(basename "$0") --env uat > /tmp/uat.yaml
EOF
}

parse_common_args "$@"
resolve_env
require_cmd kubectl

kubectl kustomize "$OVERLAY"
