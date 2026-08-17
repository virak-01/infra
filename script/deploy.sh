#!/usr/bin/env bash
# Apply the overlay. Calls cluster.sh first, exactly as `make deploy` depended on it.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env <name>] [--cloud <name>] [--host <fqdn>] [--skip-cluster]

  --host          override the Ingress host after applying (not committed)
  --skip-cluster  do not apply the cluster add-ons first

  HOST=<fqdn> also works, matching the make-style form.

WHY --host IS APPLIED AFTER THE MANIFESTS: it describes one machine, not the repo. A
node's public IP is public and changes on restart without an Elastic IP, so it stays
out of git. Consequences — render.sh and diff.sh show the placeholder, not this value,
and Argo CD reverts it on its next sync since git is what it makes the cluster match.
Fine while sync is manual; put a real domain in the overlay once it is not.
EOF
}

parse_common_args "$@"
eval "set -- ${REST_ARGS}"

SKIP_CLUSTER=false
while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      [ $# -ge 2 ] || die "--host needs a value"
      HOST="$2"
      shift 2
      ;;
    --host=*)
      HOST="${1#*=}"
      shift
      ;;
    --skip-cluster)
      SKIP_CLUSTER=true
      shift
      ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

resolve_env
require_cmd kubectl

# Cluster add-ons first. Idempotent and byte-identical per cloud, so re-applying from
# a uat deploy is a no-op. The trade-off is real though: a uat deploy touches
# kube-system. Use --skip-cluster if that matters.
if [ "$SKIP_CLUSTER" = false ]; then
  "${REPO_ROOT}/script/cluster.sh" --cloud "$CLOUD"
  echo
fi

show_context
kubectl apply -k "$OVERLAY"

# A shell `if`, not a make conditional: the JSON below is full of commas, and make
# read them as its own argument separators and silently truncated the command at the
# first one. In a script the quoting is simply the shell's.
#
# JSON Patch `add` on a path that already exists REPLACES it, so this works whether
# the overlay set a host (uat) or left the rule hostless (prod).
if [ -n "$HOST" ]; then
  note "overriding Ingress host: ${HOST}"
  kubectl -n "$NS" patch ingress company-web --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/rules/0/host\",\"value\":\"${HOST}\"}]"
fi

echo
kubectl -n "$NS" get pods,svc,ingress
