#!/usr/bin/env bash
# Carry Terraform outputs into the kustomize overlays in this repo.
#
# THE SEAM THIS COVERS. Kustomize cannot read Terraform state, so a handful of values
# — the ECR registry host, the ACM certificate ARN, the VPC CIDR in the NetworkPolicy
# — exist in both terraform/ and k8s/. That is where they drift, and the drift is
# quiet: a value changes in AWS, the manifests keep the old one, and the first symptom
# is an unhealthy target group or an ImagePullBackOff.
#
#   ./script/sync-manifests.sh --check   what disagrees (exit 1 if anything does)
#   ./script/sync-manifests.sh --write   rewrite the overlays in place
#
# --check IS THE CI MODE. Run it on every pull request and the drift becomes a failed
# build instead of a broken deploy.
#
# Simpler than it was: terraform/ and k8s/ used to live in separate repositories, so
# this needed a --manifests path and a way to find the other checkout. One repo means
# both halves are always in step on disk, and only their VALUES can disagree.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") (--check | --write)

  --check   report disagreements between terraform state and the overlays; exit 1 if any
  --write   rewrite the overlays from terraform outputs

Reads terraform/infra outputs, so that stack must have been applied first.
EOF
}

MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check)
      MODE=check
      shift
      ;;
    --write)
      MODE=write
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done

[ -n "$MODE" ] || {
  usage >&2
  exit 2
}

require_cmd terraform
TF_DIR="${REPO_ROOT}/terraform/infra"
[ -d "$TF_DIR" ] || die "terraform/infra not found"

info "terraform : terraform/infra"
info "manifests : k8s/"
echo

values="$(terraform -chdir="$TF_DIR" output -json kustomize_values 2>/dev/null)" \
  || die "could not read terraform output — has terraform/infra been applied?"

# Parsed with python rather than jq: jq is not installed everywhere, python3 is on
# every machine this repo already depends on.
tf_value() {
  printf '%s' "$values" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1') or '')"
}

registry_host="$(tf_value registry_host)"
certificate_arn="$(tf_value certificate_arn)"
vpc_cidr="$(tf_value vpc_cidr)"
alb_sg="$(tf_value alb_security_group_id)"

status=0

# report <label> <file> <regex-of-current-value> <wanted>
report() {
  label="$1" file="$2" pattern="$3" wanted="$4"
  path="${REPO_ROOT}/${file}"

  [ -f "$path" ] || {
    printf '  ?  %-18s %s not found\n' "$label" "$file"
    return 0
  }
  [ -n "$wanted" ] || {
    printf '  -  %-18s not set in terraform (skipped)\n' "$label"
    return 0
  }

  current="$(grep -oE "$pattern" "$path" | head -1 || true)"

  if [ -z "$current" ]; then
    printf '  ?  %-18s no match in %s\n' "$label" "$file"
  elif [ "$current" = "$wanted" ]; then
    printf '  %sok%s %-18s %s\n' "$C_CYAN" "$C_OFF" "$label" "$current"
  else
    printf '  %s!!%s %-18s %s\n' "$C_RED" "$C_OFF" "$label" "$current"
    printf '     %-18s %s  (terraform)\n' "" "$wanted"
    status=1
  fi
}

info "values:"
report "registry" "k8s/overlays/prod/kustomization.yaml" \
  '[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com' "$registry_host"
report "certificate" "k8s/components/ingress-alb/kustomization.yaml" \
  'arn:aws:acm:[^[:space:]]+' "$certificate_arn"
report "vpc cidr" "k8s/components/ingress-alb/kustomization.yaml" \
  'cidr: [0-9./]+' "cidr: ${vpc_cidr}"
echo

if [ "$MODE" = check ]; then
  if [ $status -eq 0 ]; then
    note "manifests agree with terraform state"
  else
    warn "DRIFT: run with --write, or fix the manifests by hand"
  fi
  exit $status
fi

# ------------------------------------------------------------------------- write

info "rewriting…"

# GNU and BSD sed disagree about -i. Detected once rather than assumed, because this
# runs on both a macOS laptop and a Linux CI runner.
sed_i() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

for f in "${REPO_ROOT}"/k8s/overlays/*/kustomization.yaml; do
  [ -f "$f" ] || continue
  sed_i -E "s|[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com|${registry_host}|g" "$f"
  info "  ${f#"${REPO_ROOT}/"}"
done

alb="${REPO_ROOT}/k8s/components/ingress-alb/kustomization.yaml"
if [ -f "$alb" ]; then
  [ -n "$certificate_arn" ] && sed_i -E "s|arn:aws:acm:[^[:space:]]+|${certificate_arn}|" "$alb"
  [ -n "$vpc_cidr" ] && sed_i -E "s|cidr: [0-9./]+|cidr: ${vpc_cidr}|" "$alb"
  info "  ${alb#"${REPO_ROOT}/"}"
fi

echo
note "done. Review before committing:  git diff"
echo
info "NOT rewritten — these need a human decision:"
info "  * image newTag: values            a release choice, never derived"
info "  * Ingress hosts in the overlays    external-dns writes the records, but the"
info "                                     host still has to be declared"
info "  * the ALB security-group annotation, which is not in the manifests yet:"
info "      alb.ingress.kubernetes.io/security-groups: ${alb_sg}"
