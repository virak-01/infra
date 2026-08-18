#!/usr/bin/env bash
# Run a command with .env loaded into the environment.
#
# THE GAP THIS FILLS: nothing reads .env on its own. Not terraform, not the aws CLI,
# not bash. A .env file is a convention, and a correctly-filled one has no effect
# until something exports it — which is why a broken .env and a missing .env look
# identical from the outside.
#
#   ./script/with-aws-env.sh terraform -chdir=terraform/infra plan
#   ./script/with-aws-env.sh aws sts get-caller-identity
#   ./script/with-aws-env.sh --whoami
#
# WHY A WRAPPER RATHER THAN `source .env` IN YOUR SHELL: credentials loaded into an
# interactive shell stay there for the rest of the session, including for every other
# command and every other repo you cd into. This scopes them to one process.
#
# Values are never printed. The checks below report on shape and presence only.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args...]
       $(basename "$0") --whoami

  --whoami   load .env and print which AWS identity it resolves to

Loads ${ENV_FILE#"${REPO_ROOT}/"} and execs the command with it in scope. Nothing is
exported into your interactive shell.

Set ENV_FILE=<path> to use a different file.
EOF
}

[ $# -gt 0 ] || {
  usage >&2
  exit 2
}
case "$1" in -h | --help)
  usage
  exit 0
  ;;
esac

[ -f "$ENV_FILE" ] || die "${ENV_FILE#"${REPO_ROOT}/"} not found — copy .env.example to .env"

# ---------------------------------------------------------------- permissions
#
# A credentials file readable by other accounts on the machine is a credentials leak
# on any shared or multi-user box. Fixed rather than warned about: there is no reason
# to want it group- or world-readable, and a warning people scroll past protects
# nobody.
if [ "$(uname)" = "Darwin" ]; then
  mode="$(stat -f '%Lp' "$ENV_FILE")"
else
  mode="$(stat -c '%a' "$ENV_FILE")"
fi
if [ "$mode" != "600" ] && [ "$mode" != "400" ]; then
  warn "tightening ${ENV_FILE##*/} from mode ${mode} to 600"
  chmod 600 "$ENV_FILE"
fi

# -------------------------------------------------------------------- loading
#
# `set -a` exports every subsequent assignment, which is what turns a plain KEY=value
# file into environment variables. Sourcing without it defines shell variables that
# child processes — terraform among them — never see.
#
# Sourced rather than parsed, so quoting and `export` lines in the file work as
# written. The trade is that .env is EXECUTED: a stray backtick in it runs as a
# command. That is acceptable for a gitignored file you wrote yourself, and it is why
# this refuses to load one that is writable by anyone else.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# ------------------------------------------------------------------- sanity
#
# Presence checks only. Whether a credential is VALID is a question only AWS can
# answer — use --whoami for that.

if [ -n "${AWS_PROFILE:-}" ] && [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  # Not an error, but the resolution order surprises people: static keys take
  # precedence and AWS_PROFILE is silently ignored, so the account you end up in is
  # not the one you named.
  warn "both AWS_PROFILE and AWS_ACCESS_KEY_ID are set — the static keys win and the profile is ignored"
fi

if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  die "${ENV_FILE##*/} sets neither AWS_PROFILE nor AWS_ACCESS_KEY_ID — see .env.example"
fi

# An ASIA-prefixed key is temporary and is refused without the session token, with an
# error that blames the key rather than the missing third value.
case "${AWS_ACCESS_KEY_ID:-}" in
  ASIA*)
    [ -n "${AWS_SESSION_TOKEN:-}" ] \
      || die "AWS_ACCESS_KEY_ID starts with ASIA (temporary credentials) but AWS_SESSION_TOKEN is not set — the API will reject this as an invalid security token"
    ;;
  AKIA* | "") ;;
  *) warn "AWS_ACCESS_KEY_ID does not look like an access key id (expected AKIA or ASIA)" ;;
esac

if [ "$1" = "--whoami" ]; then
  require_cmd aws
  info "env file : ${ENV_FILE#"${REPO_ROOT}/"}"
  info "region   : ${AWS_REGION:-${AWS_DEFAULT_REGION:-unset}}"
  info "source   : ${AWS_PROFILE:+profile ${AWS_PROFILE}}${AWS_ACCESS_KEY_ID:+static key ${AWS_ACCESS_KEY_ID:0:4}****}"
  echo
  aws sts get-caller-identity --output table
  exit 0
fi

# exec, not a subshell call: the command replaces this process, so its exit code is
# this script's exit code and signals reach it directly. A `terraform apply`
# interrupted with Ctrl-C must receive the interrupt itself, or it leaves state locked.
exec "$@"
