#!/usr/bin/env bash
# Fetch the AWS-published IAM policy for the load balancer controller.
#
# Run once before the first `terraform plan` in terraform/infra. The file is gitignored:
# it is upstream's, pinned by the version below, and not ours to edit.
#
# Why this is not inline HCL: the policy is ~180 statements with specific
# conditions and is revised per controller release. A hand-copied version fails
# at ALB-creation time with an AccessDenied naming an action you did not know the
# controller needed — a bad trade against one curl.
#
# THE VERSION MUST MATCH the chart's controller image in terraform/platform/main.tf.
# A newer controller may call actions an older policy does not grant.
set -euo pipefail

LBC_VERSION="${LBC_VERSION:-v2.8.2}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${repo_root}/terraform/modules/iam-irsa/policies"
target="${dest}/alb-controller.json"
url="https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json"

mkdir -p "${dest}"

echo "fetching load balancer controller policy ${LBC_VERSION}"
echo "  ${url}"

# Download to a temp file first: a failed curl must not leave a truncated policy
# in place, because Terraform would attach it happily and the controller would
# fail at runtime instead.
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

if ! curl -fsSL "${url}" -o "${tmp}"; then
  echo "ERROR: download failed. Check that ${LBC_VERSION} is a real release tag:" >&2
  echo "  https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases" >&2
  exit 1
fi

# Valid JSON, and actually a policy document — a 404 HTML page also downloads
# with exit 0 under some proxies.
if ! python3 -c "
import json,sys
d=json.load(open('${tmp}'))
assert 'Statement' in d, 'no Statement key — not an IAM policy document'
print(f\"  {len(d['Statement'])} statements\")
"; then
  echo "ERROR: downloaded file is not an IAM policy document." >&2
  exit 1
fi

mv "${tmp}" "${target}"
trap - EXIT

echo "wrote ${target#"${repo_root}/"}"
echo
echo "next: cd terraform/infra && terraform init && terraform plan"
