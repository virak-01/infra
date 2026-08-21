# ALB Ingress — why it returned 503, and what is still broken

Cluster `company-kubeadm-prod` (account `866409326838`, `us-east-1`), ALB
`k8s-prod-companyw-418f6c6803-626461694.us-east-1.elb.amazonaws.com`, created by
the `company-web` Ingress in namespace `prod`.

Two independent faults. The first is fixed; the second was hidden behind it and
is still open.

> **Status:** all four EC2 instances are currently **stopped**, so the ALB serves
> nothing at all right now. On restart, note that the nodes have no Elastic IPs —
> public addresses will change again. That does not affect kubectl, because
> [kubectl-access.md](kubectl-access.md) reaches the API over SSM by instance ID
> rather than by IP, and instance IDs are stable across stop/start.

---

## Fault 1 — `503`: the ALB had no targets (FIXED)

Every path returned `503 Service Temporarily Unavailable` from `awselb/2.0`.
All three target groups were **completely empty** — the ALB had nowhere to send
traffic.

The controller stated the cause on every reconcile loop:

```
"error":"providerID is not specified for node: ip-10-40-24-143"
```

### Root cause

The Ingress uses `alb.ingress.kubernetes.io/target-type: instance`. In instance
mode the AWS Load Balancer Controller must map each Kubernetes node to an EC2
instance ID, and the only field it will use is the node's **`spec.providerID`**.

`providerID` is populated by an AWS cloud-provider integration. **EKS sets it
automatically; kubeadm does not**, and `terraform/infra-kubeadm` installs no
cloud controller manager. So it was empty on all four nodes and the controller
could not register anything.

> `target-type: ip` is the usual workaround for this, but it **cannot work
> here**: pods run on the Calico overlay (`192.168.0.0/16`), which is not
> routable from the VPC (`10.40.0.0/16`). IP mode requires VPC-native pod IPs.

### The fix — two steps, both required

**Step 1. Set `providerID` on every node.**

```sh
kubectl patch node ip-10-40-24-143 -p '{"spec":{"providerID":"aws:///us-east-1b/i-093bd099366a37797"}}'
kubectl patch node ip-10-40-32-17  -p '{"spec":{"providerID":"aws:///us-east-1c/i-07f4c68adede54874"}}'
kubectl patch node ip-10-40-9-70   -p '{"spec":{"providerID":"aws:///us-east-1a/i-0f8f69c51ddf7562e"}}'
kubectl patch node ip-10-40-2-157  -p '{"spec":{"providerID":"aws:///us-east-1a/i-0d6445f5c28651d26"}}'
```

Format is `aws:///<availability-zone>/<instance-id>`.

> **All nodes, not just one.** The controller aborts the *entire* reconcile at
> the first node missing the field — it does not register the good ones and skip
> the rest. Patching one node changes nothing visible; the error message just
> moves to the next node. This is the single most confusing part of the failure.

> **`spec.providerID` is immutable once set.** A wrong value can only be undone
> by removing and rejoining the node. Verify against the EC2 API first.

**Step 2. Restart the controller.**

```sh
kubectl -n kube-system rollout restart deploy/aws-load-balancer-controller
```

Even with all four nodes patched, targets still did not appear. The controller
had accumulated enough consecutive failures that controller-runtime's
exponential backoff had pushed the next retry far into the future. A restart
forces a fresh reconcile; targets registered within seconds.

### Making it durable — done in Terraform (2026-08-21)

The manual patches above fix only the nodes that exist at the time. Any node
joining later came up with `<none>` and silently fell out of the load balancer,
with no error until traffic dropped.

That is now handled at bootstrap. `script/bootstrap/install-containerd.sh` gained
a `configure_provider_id()` function which reads the instance's AZ and ID from
IMDSv2 and writes:

```
/etc/default/kubelet:  KUBELET_EXTRA_ARGS=--provider-id=aws:///<az>/<instance-id>
```

It is called from both `control-plane.sh` and `worker.sh` **before** `kubeadm
init` / `kubeadm join`, because `spec.providerID` is immutable once the Node
object exists — setting it afterwards is impossible.

`/etc/default/kubelet` is the right seam: kubeadm's own drop-in
(`/etc/systemd/system/kubelet.service.d/10-kubeadm.conf`) carries
`EnvironmentFile=-/etc/default/kubelet` and passes `$KUBELET_EXTRA_ARGS` to the
kubelet, so the flag survives kubeadm regenerating its config.

> **Applying this replaces the instances.** `modules/ec2/main.tf` sets
> `user_data_replace_on_change = true`, so changing the bootstrap scripts makes
> Terraform destroy and recreate every node. That is what puts the flag in place
> on a fresh registration — but it is a full cluster rebuild, not an in-place
> edit. Plan accordingly.

For an existing cluster you do not want to rebuild, patch by hand instead (see
above) and let the Terraform change take effect the next time nodes are created.

The heavier alternative remains the **AWS Cloud Controller Manager**, which sets
`providerID` itself and also handles node lifecycle. The kubelet flag is the
lighter fix and needs no extra workload in the cluster.

---

## Fault 2 — intermittent `504`: cross-node pod networking is broken (OPEN)

With targets registered, `/` returns a real `200` with the Nuxt page — but only
sometimes. It alternates with `504 Gateway Time-out`, and `/api/health` fails
consistently.

### What was measured

From `ip-10-40-32-17`:

```
local pods    192.168.236.146:3000 -> 200    OK
              192.168.236.149:3000 -> 404    OK (a real HTTP reply)
cross-node    192.168.216.140:3000 -> 000    timeout
              192.168.216.141:3000 -> 000    timeout
              192.168.216.139:3000 -> 000    timeout
```

Calico looks healthy by every normal check, which is what makes this subtle:

- BGP is `Established` to both peers (`birdcl show protocols`)
- the route exists: `192.168.216.128/26 via 10.40.24.143 dev tunl0 proto bird onlink`
- plain node-to-node ping is clean, 0% packet loss
- all `calico-node` pods are Ready

So node-to-node IP works and routing is correct. What fails is specifically the
**IP-in-IP encapsulated traffic** (`ipipMode: Always`).

### Why it surfaces as intermittent 504s

The Services use `externalTrafficPolicy: Cluster`, so a request arriving at any
node's NodePort is load-balanced to *any* endpoint cluster-wide. When kube-proxy
on worker-3 selects a pod on worker-2, the connection times out and the ALB
returns 504.

| Service | Pods | Result |
|---|---|---|
| `api-auth-web` | both workers | mostly healthy |
| `employee-web` | both workers | ~50% failures → intermittent 504 on `/` |
| `api-core-web` | **worker-2 only** | every request from worker-3 crosses nodes → always fails → `/api/health` always 504 |

### AWS layer: ruled out (verified 2026-08-20)

All three AWS-level suspects were checked against the API and **none of them is
the cause**. Recording the evidence so nobody re-checks them:

| Check | Finding | Verdict |
|---|---|---|
| Worker SG `sg-0acdcb8efa8c47ad7` | has `-1` (all protocols) inbound from **itself** and from the control-plane SG | IPIP (protocol 4) is permitted |
| Network ACLs, both worker subnets | `acl-087657c5fbae17bdd`, rule 100 `allow -1 0.0.0.0/0` ingress **and** egress | not blocking |
| `SourceDestCheck` | `True` on both workers | correct for IPIP — the outer header carries node IPs, so the check passes |

> An earlier revision of this document asserted the security group was ruled out
> before it had actually been read. What had been checked at that point was the
> *control-plane* SG (`sg-0bcb64bdc00557c6e`), not the worker SG that governs the
> worker-to-worker traffic which is actually failing. The worker SG has since
> been read directly and is genuinely fine — but the conclusion was reached
> before the evidence, which is worth flagging.

```sh
aws ec2 describe-security-groups --group-ids sg-0acdcb8efa8c47ad7 \
  --query 'SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,SrcSG:UserIdGroupPairs[].GroupId}'

aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=subnet-025e5c77ae0b7e5d6"

aws ec2 describe-instances --instance-ids i-093bd099366a37797 i-07f4c68adede54874 \
  --query 'Reservations[].Instances[].SourceDestCheck'
```

### Next to check: the host layer

Since AWS is not dropping the packets, the fault is inside the instances. In
order of likelihood:

1. **`rp_filter`** — strict reverse-path filtering (`net.ipv4.conf.*.rp_filter=1`)
   discards decapsulated IPIP packets, because the inner source address does not
   match the route back out of `tunl0`. This is the classic Calico-on-AWS cause
   and fits the symptoms exactly.
2. **The `ipip` kernel module** — confirm it is loaded and `tunl0` is `UP`.
3. **`tunl0` counters and iptables** — whether packets are leaving at all, and
   whether any `cali-*` chain is dropping them.

The decisive test is a packet capture on the sending node, which distinguishes
"never transmitted" from "transmitted but never answered":

```sh
# on the sending worker, while curling a pod on the other worker
tcpdump -ni enX0 proto 4 -c 10
sysctl -n net.ipv4.conf.all.rp_filter net.ipv4.conf.tunl0.rp_filter
lsmod | grep ipip
ip -s -br link show tunl0
```

**Not yet run** — all four instances were stopped before the capture could be
taken.

---

## Gotcha: use `/`, not `/employee`

`/employee` returns **404 regardless of any of the above** — confirmed by
querying the pod directly, bypassing the ALB entirely:

```
/            -> 200
/employee    -> 404
/employee/   -> 404
```

This deployment sets `NUXT_APP_BASE_URL=/`, so the app serves at the root, and
the Ingress has no `/employee` rule — its only frontend rule is `/` →
`employee-web`. The `/employee/` prefix belongs to the *other* cluster, where
`NUXT_APP_BASE_URL=/employee/`. Do not carry the URL between them.

The correct URL is the bare root:

```
http://k8s-prod-companyw-418f6c6803-626461694.us-east-1.elb.amazonaws.com/
```

---

## Unrelated but worth fixing: probe timeouts

`employee-web` had restarted **52 times**. Its probes use `timeoutSeconds: 1`
with `initialDelaySeconds: 2` — far too tight for server-side rendering. The app
itself is fast (0.24s when measured directly), so the restarts were the probes
failing, not the app. Once targets are registered this also shows up as targets
flapping in and out of the ALB.

```sh
kubectl -n prod patch deploy employee-web --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/timeoutSeconds","value":5},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds","value":10},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/timeoutSeconds","value":5},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":20}
]'
```
