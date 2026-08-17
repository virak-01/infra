#!/usr/bin/env bash
# Load k8s/overlays/<env>/app-config.env into the cluster as the website-config ConfigMap.
#
# The overlay has no configMapGenerator on purpose: app-config.env is gitignored, and
# Argo CD renders from git — a generator pointing at a file absent from the repo fails
# the whole sync. So the ConfigMap is applied out of band, the same way ecr-creds is.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "Usage: $(basename "$0") [--env <name>]    # apply website-config, then restart"; }

parse_common_args "$@"
resolve_env
require_cmd kubectl

ENV_FILE="${OVERLAY}/app-config.env"
[ -f "$ENV_FILE" ] \
  || die "${ENV_FILE#"${REPO_ROOT}/"} missing — copy app-config.env.example"

show_context

kubectl -n "$NS" create configmap website-config \
  --from-env-file="$ENV_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

# THE RESTART IS DELIBERATE, NOT INCIDENTAL. The ConfigMap name carries no content
# hash, so the pod template is unchanged and nothing rolls on its own — an edit would
# otherwise apply only to pods that happened to restart later.
note "restarting so the new values are picked up"

# EVERY Deployment in the namespace, not a named pair. This used to name employee-web
# and user-web only, so after api-auth and api-core were added they kept running with
# the OLD config — and `2>/dev/null || true` hid it, because a restart of a
# non-existent Deployment fails silently. Every workload here consumes website-config
# via envFrom, so every one has to roll.
if ! kubectl -n "$NS" rollout restart deploy 2>/dev/null; then
  info "  (no Deployments yet — they will read the ConfigMap on first start)"
fi
