#!/usr/bin/env bash
# Block until every node has joined and reports Ready, or fail loudly.
#
# WHY THIS EXISTS. `terraform apply` finishes when the AWS API accepts RunInstances.
# That says six machines were created; it says nothing about whether Kubernetes formed
# on them. Every failure in this stack that matters — a control plane that never
# finished kubeadm init, a worker whose token expired, a CNI that never applied —
# happens AFTER the last API call Terraform makes, so a successful apply and a dead
# cluster look identical from Terraform's side.
#
# This closes that gap. modules/ec2 runs it from a local-exec provisioner, so a cluster
# that does not form fails the apply instead of being discovered later by hand.
#
# Runs the check ON the control plane over SSM rather than connecting to the API
# server directly: that needs no kubeconfig on this machine, no 6443 reachability, and
# no security-group entry for whoever happens to be running Terraform.
#
#   ./script/wait-for-nodes.sh --instance i-0abc --expect 6
#   ./script/wait-for-nodes.sh --instance i-0abc --expect 6 --timeout 900
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") --instance <control-plane-id> --expect <n> [options]

  --instance <id>   control-plane instance id (terraform output control_plane_instance_id)
  --expect <n>      nodes that must report Ready, control plane included
  --timeout <s>     give up after this many seconds (default 1200)
  --region <name>   AWS region (default: AWS_REGION, then AWS_DEFAULT_REGION, then us-east-1)
  --interval <s>    seconds between checks (default 20)

Exits 0 when <n> nodes are Ready, 1 on timeout with the control plane's own log.
EOF
}

INSTANCE=""
EXPECT=""
TIMEOUT=1200
INTERVAL=20
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

while [ $# -gt 0 ]; do
  case "$1" in
    --instance)
      INSTANCE="${2:?--instance needs a value}"
      shift 2
      ;;
    --expect)
      EXPECT="${2:?--expect needs a value}"
      shift 2
      ;;
    --timeout)
      TIMEOUT="${2:?--timeout needs a value}"
      shift 2
      ;;
    --interval)
      INTERVAL="${2:?--interval needs a value}"
      shift 2
      ;;
    --region)
      REGION="${2:?--region needs a value}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$INSTANCE" ] && [ -n "$EXPECT" ] || {
  usage >&2
  exit 2
}
command -v aws >/dev/null 2>&1 || {
  echo "ERROR: the aws CLI is required" >&2
  exit 1
}

# Run a command on the control plane and return its stdout. Every AWS call here is
# tolerated failing: SSM refuses until the agent registers, which takes a minute or two
# after boot, and that is a normal part of waiting rather than an error.
#
# TOLERATED, NOT DISCARDED. These calls used to send stderr to /dev/null, which made
# "the agent has not registered yet" and "your credentials cannot call ssm:SendCommand"
# produce the same thing: nothing at all, for the full twenty minutes. AWS answers the
# second one in milliseconds and the message says exactly what is wrong, so it is kept
# here and reported by the caller once failing stops looking like a slow boot.
ERR_FILE=$(mktemp) # raw stderr of the most recent AWS call
MSG_FILE=$(mktemp) # the formatted reason the most recent check failed
trap 'rm -f "$ERR_FILE" "$MSG_FILE"' EXIT

# WHY THE REASON GOES IN A FILE AND NOT A VARIABLE. on_control_plane is called as
# `count=$(on_control_plane ...)`, and a command substitution runs in a SUBSHELL: every
# variable it assigns is discarded when the substitution ends, so a `LAST_ERR=...` set
# inside it is invisible to the loop that has to print it. A file crosses that boundary.
#
# The message is flattened to one line — the CLI wraps long errors, and a multi-line
# string in the middle of the progress output is harder to read than the cause is long.
note_err() {
  local msg
  msg=$(tr -s '[:space:]' ' ' <"$ERR_FILE" | sed 's/^ *//;s/ *$//')
  printf '%s: %s' "$1" "${msg:-no message}" >"$MSG_FILE"
}

last_err() { cat "$MSG_FILE"; }

on_control_plane() {
  local cid out

  # Cleared per call, so the fallback at the bottom cannot inherit an older reason.
  : >"$MSG_FILE"

  if ! cid=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"$1\"]" \
    --query Command.CommandId --output text 2>"$ERR_FILE"); then
    note_err "ssm send-command"
    return 1
  fi

  # SSM is asynchronous: the invocation does not exist for a moment after send.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    if ! out=$(aws ssm get-command-invocation \
      --region "$REGION" \
      --command-id "$cid" \
      --instance-id "$INSTANCE" \
      --query StandardOutputContent --output text 2>"$ERR_FILE"); then
      note_err "ssm get-command-invocation"
      continue
    fi
    [ "$out" = "None" ] && continue
    : >"$MSG_FILE"
    printf '%s' "$out"
    return 0
  done

  # Sent but never answered. The agent is registered — send-command validated the id —
  # and is not running the command, which is what an Offline agent looks like.
  [ -s "$MSG_FILE" ] || printf 'command %s sent, no output after 30s (agent Offline?)' "$cid" >"$MSG_FILE"
  return 1
}

KUBECTL='kubectl --kubeconfig /etc/kubernetes/admin.conf'

echo "waiting for ${EXPECT} Ready nodes (timeout ${TIMEOUT}s, control plane ${INSTANCE})"

deadline=$((SECONDS + TIMEOUT))
ready=0
last=""
fails=0

while ((SECONDS < deadline)); do
  # `grep -cw Ready` and not `grep -c Ready`: a node in the NotReady state contains
  # the substring, so the unanchored form counts exactly the nodes that are broken.
  if count=$(on_control_plane "${KUBECTL} get nodes --no-headers 2>/dev/null | grep -cw Ready || true"); then
    fails=0
    ready=$(printf '%s' "$count" | tr -cd '0-9')
    ready=${ready:-0}

    if [ "$ready" -ge "$EXPECT" ]; then
      echo "all ${ready} nodes Ready"
      exit 0
    fi

    # Reprinted only when it changes, so a long wait does not scroll a plan out of
    # the terminal. The elapsed count still moves, so it never looks hung.
    if [ "$ready" != "$last" ]; then
      echo "  ${ready}/${EXPECT} Ready (${SECONDS}s elapsed)"
      last="$ready"
    fi
  else
    # THE SILENCE THIS REPLACES. A wait where SSM never answers printed one line and
    # then nothing for twenty minutes, which is indistinguishable from a cluster
    # forming slowly — and the two want opposite responses. The first few failures
    # really are normal (the agent registers a minute or two after boot), so this
    # stays quiet through those and then says what AWS is actually returning.
    fails=$((fails + 1))
    if [ "$fails" -eq 3 ] || [ $((fails % 10)) -eq 0 ]; then
      echo "  no answer over SSM after ${fails} attempts (${SECONDS}s): $(last_err)"
    fi
  fi

  sleep "$INTERVAL"
done

# ─── failed: say why, with the evidence ──────────────────────────────────────
#
# A bare "timed out" sends the reader off to find the logs by hand, on a machine they
# probably cannot SSH to. The control plane's own log is the thing that explains it, so
# fetch it here while the SSM path is already known to work.
#
# TWO DIFFERENT FAILURES END UP HERE and they have nothing in common. Either the SSM
# path never worked — in which case nothing is known about the cluster and everything
# below about kubeadm is a guess — or the cluster was seen and did not converge.
# `last` tells them apart: it is set only by a check that actually answered.

if [ "$fails" -gt 0 ] && [ -z "$last" ]; then
  cat >&2 <<EOF

ERROR: could not reach the control plane over SSM in ${TIMEOUT}s. The cluster was
never observed, so this says nothing about whether it formed.

Last error:
  $(last_err)

Check, in this order:

  # is the instance registered with SSM at all? An empty list is the answer.
  aws ssm describe-instance-information --region ${REGION} \\
    --filters Key=InstanceIds,Values=${INSTANCE}

  # can THESE credentials call it? AccessDenied here is a caller problem, not a node one.
  aws sts get-caller-identity
  aws ssm send-command --region ${REGION} --instance-ids ${INSTANCE} \\
    --document-name AWS-RunShellScript --parameters 'commands=["uptime"]'

An Offline or absent agent on a node that is running usually means the instance profile
lost AmazonSSMManagedInstanceCore, or the subnet lost its route out. Set
wait_for_nodes = false to stop gating the apply on a check that cannot run.
EOF
  exit 1
fi

cat >&2 <<EOF

ERROR: ${ready}/${EXPECT} nodes Ready after ${TIMEOUT}s.

The instances exist — this is Kubernetes not forming on them. The control plane's
bootstrap log follows.
EOF

if log=$(on_control_plane "tail -30 /var/log/k8s-bootstrap.log 2>&1; echo ---; systemctl is-active k8s-bootstrap.service"); then
  printf '\n%s\n' "$log" >&2
else
  echo "  (could not reach the control plane over SSM — check its IAM role and that the agent is Online)" >&2
fi

cat >&2 <<EOF

What each outcome means:

  0 Ready          kubeadm init failed. The log above ends at the failing step.
  1 Ready          the control plane is fine; workers did not join. Check one:
                     aws ssm start-session --target <worker-id>
                     sudo journalctl -u k8s-bootstrap.service -n 50
  N NotReady       the CNI never applied. On the control plane:
                     kubectl -n kube-system get pods | grep calico

Nothing needs destroying. The bootstrap is a systemd unit that retries every minute,
so a transient cause may still resolve on its own — re-run \`terraform apply\` to wait
again, or set wait_for_nodes = false to stop gating the apply on it.
EOF

exit 1
