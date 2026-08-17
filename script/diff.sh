#!/usr/bin/env bash
# Show what applying would change in the live cluster. Read-only against the cluster.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "Usage: $(basename "$0") [--env <name>]    # kubectl diff against the live cluster"; }

parse_common_args "$@"
resolve_env
require_cmd kubectl
show_context
echo

# EXIT CODE 1 IS THE NORMAL CASE, not an error: kubectl diff exits 0 only when the
# live state already equals the overlay. Anything above 1 is a real failure — a lost
# connection, a bad manifest — and must still propagate, which is why this tests for
# exactly 1 rather than swallowing every non-zero code.
set +e
kubectl diff -k "$OVERLAY"
rc=$?
set -e

case $rc in
  0) note "no differences — the cluster already matches ${ENV}" ;;
  1) exit 0 ;;
  *) die "kubectl diff failed (exit ${rc})" ;;
esac
