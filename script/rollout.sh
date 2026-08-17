#!/usr/bin/env bash
# Wait for every Deployment in ENV to finish rolling out.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env <name>] [--timeout <seconds>]

Waits on every Deployment the namespace actually has. Default timeout 180s each.
EOF
}

parse_common_args "$@"
eval "set -- ${REST_ARGS}"

TIMEOUT=180
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --timeout=*)
      TIMEOUT="${1#*=}"
      shift
      ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

resolve_env
require_cmd kubectl
show_context
echo

# DERIVED FROM THE CLUSTER, never from a list in a file. An earlier version looped over
# a hardcoded `employee user`, so once api-auth and api-core existed it waited on two of
# four Deployments and reported success while an API was still crash-looping. Any list
# here would be a second copy of k8s/base/kustomization.yaml's service list, and copies
# drift.
deploys="$(kubectl -n "$NS" get deploy -o name 2>/dev/null || true)"

[ -n "$deploys" ] \
  || die "no Deployments in namespace ${NS} — run: ./script/deploy.sh --env ${ENV}"

status=0
for d in $deploys; do
  kubectl -n "$NS" rollout status "$d" --timeout="${TIMEOUT}s" || status=1
done

[ $status -eq 0 ] || die "one or more Deployments did not roll out within ${TIMEOUT}s"
note "all Deployments rolled out"
