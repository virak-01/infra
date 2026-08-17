#!/usr/bin/env bash
# Shared helpers. Sourced by every script here; not executable on its own.
#
# WHY THIS FILE EXISTS. Eleven scripts all need the same four derivations — repo root,
# ENV, the overlay path, the namespace — and eleven copies of that would drift the
# moment one changed. This is the single place ENV becomes a path.
#
# BASH 3.2 COMPATIBLE. macOS still ships 3.2, and these run on operators' laptops, so
# nothing here uses mapfile, readarray, associative arrays or ${var^^}.

# ---------------------------------------------------------------------- repo root
#
# Resolved from this file's own location, not from $PWD, so every script works from
# anywhere: `./script/deploy.sh`, `script/deploy.sh`, or an absolute path from cron.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ------------------------------------------------------------------------- output

if [ -t 1 ]; then
  C_CYAN=$'\033[36m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'
  C_OFF=$'\033[0m'
else
  # Not a terminal — a CI log or a pipe. Escape codes there are noise that also
  # breaks grep on the output.
  C_CYAN='' C_RED='' C_YELLOW='' C_BOLD='' C_OFF=''
fi

info() { printf '%s\n' "$*"; }
note() { printf '%s→ %s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die() {
  printf '%sERROR: %s%s\n' "$C_RED" "$*" "$C_OFF" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed${2:+ — $2}"
}

# ---------------------------------------------------------------------- variables
#
# Every one is overridable from the environment, so the make-style invocation still
# works and reads the same:
#
#   ENV=uat ./script/deploy.sh          (or: ./script/deploy.sh --env uat)

ENV="${ENV:-prod}"
CLOUD="${CLOUD:-aws}"
HOST="${HOST:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REGISTRY="${ECR_REGISTRY:-043309361013.dkr.ecr.${AWS_REGION}.amazonaws.com}"

# ------------------------------------------------------------------- arg parsing
#
# Accepts `--env uat` and `--cloud gcp` alongside the environment-variable form. Any
# argument this does not recognise is left in REST_ARGS for the calling script, which
# is what lets deploy.sh take --host without every script knowing about it.
REST_ARGS=""

parse_common_args() {
  REST_ARGS=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -e | --env)
        [ $# -ge 2 ] || die "--env needs a value"
        ENV="$2"
        shift 2
        ;;
      --env=*)
        ENV="${1#*=}"
        shift
        ;;
      -c | --cloud)
        [ $# -ge 2 ] || die "--cloud needs a value"
        CLOUD="$2"
        shift 2
        ;;
      --cloud=*)
        CLOUD="${1#*=}"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        # Preserved with quoting so a value containing spaces survives the
        # round-trip through eval in the caller.
        REST_ARGS="${REST_ARGS} $(printf '%q' "$1")"
        shift
        ;;
    esac
  done
}

# ------------------------------------------------------------------ env -> paths
#
# THE NAMESPACE IS THE ENVIRONMENT. uat and prod share one cluster and each overlay
# declares `namespace: <env>`, so one value drives both the directory and the -n flag.

resolve_env() {
  OVERLAY="${REPO_ROOT}/k8s/overlays/${ENV}"
  NS="$ENV"

  # NOT IN THE MAKEFILE, and worth adding. `make deploy ENV=prodd` derived
  # NS=prodd and only failed later, at the kustomize step — while `make current
  # ENV=prodd` reported "no deployments" for a namespace that never existed, which
  # reads as an empty environment rather than as a typo. Failing here names the
  # mistake and lists the real answers.
  if [ ! -d "$OVERLAY" ]; then
    printf '%sERROR: no overlay for ENV=%s%s\n' "$C_RED" "$ENV" "$C_OFF" >&2
    printf '  looked for: %s\n' "${OVERLAY#"${REPO_ROOT}/"}" >&2
    printf '  available : %s\n' "$(ls "${REPO_ROOT}/k8s/overlays" | tr '\n' ' ')" >&2
    exit 1
  fi

  CLUSTER_ADDONS="${REPO_ROOT}/k8s/cluster/${CLOUD}"
}

# ------------------------------------------------------------------ cluster guard
#
# Printed before anything that touches a cluster. uat and prod share one, so the
# context is the only thing distinguishing "the right cluster" from "someone else's",
# and it is cheap to show every time.

show_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null)" || ctx=""
  [ -n "$ctx" ] || die "no current kubectl context — run: kubectl config use-context <name>"
  info "context:   ${C_BOLD}${ctx}${C_OFF}"
  [ -n "${NS:-}" ] && info "namespace: ${NS}"
  return 0
}

# Default usage. Each script overrides it before calling parse_common_args.
usage() {
  cat <<EOF
Usage: $(basename "$0") [--env <name>] [--cloud <name>]

  --env, -e     overlay and namespace to act on (default: ${ENV})
  --cloud, -c   cluster add-on set under k8s/cluster/ (default: ${CLOUD})
  --help, -h    this message

Environment variables ENV, CLOUD, HOST, AWS_REGION work too, so the make-style
form still reads the same:  ENV=uat $(basename "$0")
EOF
}
