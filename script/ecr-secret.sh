#!/usr/bin/env bash
# Mint the ECR pull Secret now, by running the refresh CronJob immediately.
#
# THE CronJob CANNOT BOOTSTRAP ITSELF. Pods pull images long before the first 8-hourly
# schedule fires, so without this the first deploy sits in ImagePullBackOff until the
# schedule happens to come round. This runs the very same job on demand.
#
# Needs no local AWS CLI: the credentials, the egress exception and the RBAC all live in
# the cluster. It only needs aws-creds.sh to have run first.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "Usage: $(basename "$0") [--env <name>]    # run the refresh CronJob now"; }

parse_common_args "$@"
resolve_env
require_cmd kubectl
show_context

JOB=ecr-credentials-refresh-now

# Checked before running, so the failure names the real cause. Without this the job
# starts, the init container exits non-zero on a missing env var, and the diagnosis is
# buried in container logs.
if ! kubectl -n "$NS" get secret aws-ecr-credentials >/dev/null 2>&1; then
  die "no aws-ecr-credentials Secret in ${NS} — run: ./script/aws-creds.sh --env ${ENV}"
fi

kubectl -n "$NS" delete job "$JOB" --ignore-not-found
kubectl -n "$NS" create job "$JOB" --from=cronjob/ecr-credentials-refresh

# ON FAILURE, SHOW STATUS AND EVENTS BEFORE LOGS. A pod that never got scheduled has no
# logs at all, so a logs-only failure path reports "no pods found" and hides the real
# reason — which lives in the events, usually FailedScheduling from a taint or exhausted
# CPU.
if ! kubectl -n "$NS" wait --for=condition=complete --timeout=120s "job/${JOB}"; then
  echo
  warn "job did not complete."
  echo
  info "--- pod ---"
  kubectl -n "$NS" get pods -l "job-name=${JOB}" -o wide || true
  echo
  info "--- events ---"
  kubectl -n "$NS" describe pod -l "job-name=${JOB}" | sed -n '/^Events:/,$p' || true
  echo
  info "--- logs (empty if the pod never started) ---"
  kubectl -n "$NS" logs -l "job-name=${JOB}" --all-containers --tail=30 2>&1 || true
  exit 1
fi

echo
kubectl -n "$NS" get secret ecr-creds
note "pull credentials minted. If pods are already stuck, roll them: ./script/app-config.sh --env ${ENV}"
