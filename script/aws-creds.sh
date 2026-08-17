#!/usr/bin/env bash
# Store the IAM key the ECR refresh job uses, as the aws-ecr-credentials Secret.
#
# TWO LEAKS IN THE MAKEFILE VERSION, BOTH CLOSED HERE.
#
#   make aws-creds AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=wJalr...
#
#   1. SHELL HISTORY. That command line is written to ~/.zsh_history verbatim, where it
#      stays until someone notices. The default here is an invisible prompt instead, so
#      the secret is never typed into a command line at all.
#
#   2. `ps` OUTPUT. `--from-literal=AWS_SECRET_ACCESS_KEY=<value>` is an ARGUMENT to
#      kubectl, and arguments are world-readable in the process table for as long as the
#      call takes. This writes a mode-600 temp file and uses --from-env-file, so the
#      value never appears in an argv.
#
# Why an IAM user key at all, rather than the node's instance profile: this cluster's
# egress NetworkPolicy blocks 169.254.169.254 so a compromised container cannot read the
# node role. A narrow, revocable credential scoped to ecr:GetAuthorizationToken is the
# trade for keeping that block intact. See k8s/components/registry-ecr/.
#
# ON EKS THIS SCRIPT IS UNNECESSARY. Grant the node role
# AmazonEC2ContainerRegistryReadOnly and drop the registry-ecr component instead.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env <name>] [--stdin]

Reads the credentials, in this order of preference:

  1. an invisible prompt          (default — nothing enters shell history)
  2. --stdin                      for a pipe or a file:
                                    ./script/aws-creds.sh --stdin < creds.env
                                  expecting KEY=value lines
  3. the environment              AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
                                  (and optional AWS_SESSION_TOKEN) — for CI, where
                                  the values come from a secret store rather than a
                                  command line

Then run: ./script/ecr-secret.sh --env <name>
EOF
}

parse_common_args "$@"
eval "set -- ${REST_ARGS}"

FROM_STDIN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --stdin)
      FROM_STDIN=true
      shift
      ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

resolve_env
require_cmd kubectl

KEY_ID="${AWS_ACCESS_KEY_ID:-}"
SECRET="${AWS_SECRET_ACCESS_KEY:-}"
TOKEN="${AWS_SESSION_TOKEN:-}"

if [ "$FROM_STDIN" = true ]; then
  # Parsed rather than sourced. `source` on untrusted input executes it, so a stray
  # backtick in a credentials file would run as a command.
  while IFS='=' read -r k v; do
    case "$k" in
      AWS_ACCESS_KEY_ID) KEY_ID="$v" ;;
      AWS_SECRET_ACCESS_KEY) SECRET="$v" ;;
      AWS_SESSION_TOKEN) TOKEN="$v" ;;
    esac
  done
elif [ -z "$KEY_ID" ] || [ -z "$SECRET" ]; then
  # Interactive prompt. -s suppresses the echo so the secret is not left on screen or
  # in a scrollback buffer.
  [ -t 0 ] || die "not a terminal and no credentials in the environment — use --stdin, or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"

  info "Credentials for the ECR refresh job (input is not echoed)."
  if [ -z "$KEY_ID" ]; then
    printf '  AWS_ACCESS_KEY_ID: '
    IFS= read -r KEY_ID
  fi
  if [ -z "$SECRET" ]; then
    printf '  AWS_SECRET_ACCESS_KEY: '
    IFS= read -rs SECRET
    echo
  fi
  if [ -z "$TOKEN" ]; then
    printf '  AWS_SESSION_TOKEN (blank if none): '
    IFS= read -rs TOKEN
    echo
  fi
fi

[ -n "$KEY_ID" ] || die "no AWS_ACCESS_KEY_ID"
[ -n "$SECRET" ] || die "no AWS_SECRET_ACCESS_KEY"

# A rough shape check. Not validation — only AWS can say whether a key works — but it
# catches the common paste error of swapping the two fields, which otherwise surfaces
# hours later as an ImagePullBackOff.
case "$KEY_ID" in
  AKIA* | ASIA*) ;;
  *) warn "warning: AWS_ACCESS_KEY_ID does not start with AKIA or ASIA — did the two values get swapped?" ;;
esac

show_context

# Mode 600 from creation, before anything is written to it: creating the file and then
# chmod-ing leaves a window in which it is readable.
umask_old="$(umask)"
umask 077
CRED_FILE="$(mktemp)"
umask "$umask_old"

# shred on exit covers the error paths too — an interrupted run must not leave the
# credential behind in /tmp.
cleanup() { shred -u "$CRED_FILE" 2>/dev/null || rm -f "$CRED_FILE"; }
trap cleanup EXIT INT TERM

{
  printf 'AWS_ACCESS_KEY_ID=%s\n' "$KEY_ID"
  printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$SECRET"
  [ -n "$TOKEN" ] && printf 'AWS_SESSION_TOKEN=%s\n' "$TOKEN"
} >"$CRED_FILE"

kubectl -n "$NS" create secret generic aws-ecr-credentials \
  --from-env-file="$CRED_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

note "stored in namespace ${NS}. Now run: ./script/ecr-secret.sh --env ${ENV}"
