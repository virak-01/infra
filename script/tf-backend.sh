#!/usr/bin/env bash
# Point every terraform backend at the state bucket that actually exists.
#
# WHY THIS EXISTS. A backend block takes no variables and no interpolation — Terraform
# reads it before evaluating anything else — so the bucket name has to be a literal.
# That literal ships as a `<ACCOUNT_ID>` placeholder, and a checkout where nobody
# replaced it fails at `terraform init` with one of two unhelpful errors:
#
#   InvalidBucketName: The specified bucket is not valid          (placeholder intact)
#   S3 bucket "..." does not exist                                (wrong name)
#
# Neither says "edit backend.tf". This discovers the real bucket and writes it in.
#
#   ./script/tf-backend.sh            show what is set and what exists
#   ./script/tf-backend.sh --write    set every backend to the discovered bucket
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--write] [--bucket <name>]

  --write           rewrite terraform/*/backend.tf with the discovered bucket
  --bucket <name>   use this name instead of discovering one

With no arguments it only reports, changing nothing.

Discovery lists S3 buckets whose name contains "tfstate". If none exists, run
terraform/bootstrap first — it creates one.
EOF
}

WRITE=false
BUCKET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --write)
      WRITE=true
      shift
      ;;
    --bucket)
      [ $# -ge 2 ] || die "--bucket needs a value"
      BUCKET="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

require_cmd aws
TF_DIR="${REPO_ROOT}/terraform"
[ -d "$TF_DIR" ] || die "terraform/ not found"

# ─── what the files currently say ────────────────────────────────────────────

info "configured:"
for f in "$TF_DIR"/*/backend.tf; do
  [ -f "$f" ] || continue
  cur="$(grep -oE '^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"[^"]*"' "$f" | head -1 | sed -E 's/.*"([^"]*)"/\1/')"
  printf '  %-28s %s\n' "$(basename "$(dirname "$f")")" "${cur:-(none)}"
done
echo

# ─── what actually exists ────────────────────────────────────────────────────

if [ -z "$BUCKET" ]; then
  # `aws s3 ls` prints "date time name"; the name is field 3.
  found="$(aws s3 ls 2>/dev/null | awk '{print $3}' | grep -i tfstate || true)"
  count="$(printf '%s' "$found" | grep -c . || true)"

  if [ "$count" = "0" ]; then
    warn "no S3 bucket matching 'tfstate' in this account."
    info "  Create one first:"
    info "    cd terraform/bootstrap && terraform init && terraform apply"
    exit 1
  fi
  if [ "$count" != "1" ]; then
    warn "more than one candidate — pass --bucket <name> to choose:"
    printf '%s\n' "$found" | sed 's/^/    /'
    exit 1
  fi
  BUCKET="$found"
fi

info "using bucket: ${C_BOLD}${BUCKET}${C_OFF}"

# Confirm it is reachable before writing it anywhere. A name that exists in another
# account, or in another region, fails here rather than at init.
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 \
  || die "cannot reach s3://${BUCKET} — wrong account, wrong region, or no permission"

if [ "$WRITE" != true ]; then
  echo
  note "nothing changed. Re-run with --write to apply."
  exit 0
fi

# ─── write it in ─────────────────────────────────────────────────────────────
#
# Matches the WHOLE bucket assignment rather than a specific old value, so this works
# whether the file holds the placeholder, a stale name, or the right one already.

sed_i() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

echo
for f in "$TF_DIR"/*/backend.tf; do
  [ -f "$f" ] || continue
  sed_i -E "s|^([[:space:]]*bucket[[:space:]]*=[[:space:]]*\")[^\"]*(\")|\1${BUCKET}\2|" "$f"
  info "  ${f#"${REPO_ROOT}/"}"
done

# platform reads infra's remote state, so it names the bucket as a variable too.
pv="${TF_DIR}/platform/terraform.tfvars"
if [ -f "$pv" ]; then
  sed_i -E "s|^([[:space:]]*state_bucket[[:space:]]*=[[:space:]]*\")[^\"]*(\")|\1${BUCKET}\2|" "$pv"
  info "  ${pv#"${REPO_ROOT}/"}"
fi

echo
note "done. Re-init any stack whose backend changed:"
info "  terraform -chdir=terraform/infra init -reconfigure"
