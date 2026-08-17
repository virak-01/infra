#!/usr/bin/env bash
# What ENV's namespace is running, and which overlay it matches. Read-only.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "Usage: $(basename "$0") [--env <name>]    # live workloads, and drift"; }

parse_common_args "$@"
resolve_env
require_cmd kubectl
show_context
echo

# CAPTURED FIRST, THEN TESTED. `kubectl get deploy ... || echo` never printed its
# fallback: with no Deployments kubectl exits 0 and writes nothing, so the `||` branch
# was unreachable and an empty namespace rendered as blank output.
out="$(kubectl -n "$NS" get deploy -o \
  jsonpath='{range .items[*]}  {.metadata.name}{"  x"}{.spec.replicas}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}' \
  2>/dev/null || true)"

if [ -n "$out" ]; then
  printf '%s\n' "$out"
else
  info "  (no deployments — nothing applied yet)"
fi
echo

# Which overlay the cluster currently matches. Still worth running even though each
# environment owns a namespace: it catches drift and mid-rollout states.
matched=""
for overlay in "${REPO_ROOT}"/k8s/overlays/*/; do
  if kubectl diff -k "$overlay" >/dev/null 2>&1; then
    info "  => live cluster matches: $(basename "$overlay")"
    matched=1
  fi
done
[ -n "$matched" ] \
  || info "  => matches no overlay exactly (mid-rollout, drifted, or a tag was edited)"
