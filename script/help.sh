#!/usr/bin/env bash
# List every script here, with the same one-line summaries `make help` printed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "Usage: $(basename "$0")"; }

printf '%sscript/%s — every command in the docs, in one place\n\n' "$C_BOLD" "$C_OFF"

# Summaries live in each script's second comment line, so they cannot drift from the
# script they describe — the same reason `make help` grepped its own targets.
for s in "${REPO_ROOT}"/script/*.sh; do
  name="$(basename "$s")"
  [ "$name" = "lib.sh" ] && continue
  [ "$name" = "help.sh" ] && continue
  summary="$(sed -n '2s/^# //p' "$s")"
  printf '  %s%-16s%s %s\n' "$C_CYAN" "${name%.sh}" "$C_OFF" "$summary"
done

cat <<EOF

  vars: ENV=${ENV}   (overlays: $(ls "${REPO_ROOT}/k8s/overlays" | tr '\n' ' '))
        CLOUD=${CLOUD}   (cluster add-ons: $(ls "${REPO_ROOT}/k8s/cluster" | tr '\n' ' '))

  Both forms work and mean the same thing:
        ENV=uat ./script/deploy.sh
        ./script/deploy.sh --env uat

  note: uat and prod share one cluster, separated by namespace.
        ENV picks the environment — it is both the overlay and the namespace.
        CLOUD picks cluster add-ons ONLY. The workload edge (ALB vs ingress-nginx)
        is a components: line in the overlay, because Argo CD renders from git and
        never runs these scripts.

  Any script accepts --help.
EOF
