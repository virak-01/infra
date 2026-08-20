# Node autoscaling

Two different things scale here, and they are often confused:

| | Scales | Trigger | Where |
|---|---|---|---|
| HorizontalPodAutoscaler | pods | CPU above 70% of request | [`k8s/base/web/hpa.yaml`](../k8s/base/web/hpa.yaml) |
| Cluster Autoscaler | nodes | pods stuck **Pending** | [`k8s/cluster/aws/cluster-autoscaler`](../k8s/cluster/aws/cluster-autoscaler) |

Cluster Autoscaler reacts to **Pending pods only**. A cluster at 99% CPU with
nothing pending will not grow. The HPA is what creates the pending pods, so
`metrics-server` must be working or neither layer does anything:

```sh
kubectl top nodes    # errors => metrics-server missing => HPAs are inert
```

## What CA actually does

It calls `SetDesiredCapacity` on an Auto Scaling Group. That is all. It does
not launch instances, and it cannot make an instance join the cluster — the
ASG launches it and the instance must join itself. On EKS a managed node group
handles that. On kubeadm we build it, and that is the bulk of this document.

`--nodes=2:6:k8s-learning-workers` in the Deployment must match the ASG's
MinSize and MaxSize. **The ASG is the hard limit**; CA can never exceed it.

## Order

Each step depends on the one above. Doing them out of order produces instances
that boot and never become nodes.

### 1. IAM

CA reads AWS credentials from the node's instance profile. kubeadm has no IRSA,
so these permissions land on the **node role**, which means every pod on that
node can use them unless IMDS is blocked. That is a real downgrade from EKS and
worth knowing before you start.

```sh
cat > /tmp/ca-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeImages"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": ["ssm:GetParameter"],
      "Resource": "arn:aws:ssm:us-east-1:866409326838:parameter/k8s/join-command"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name <YOUR_NODE_ROLE> \
  --policy-name cluster-autoscaler \
  --policy-document file:///tmp/ca-policy.json
```

The two mutating actions are tag-scoped so a leaked node credential cannot
terminate instances in unrelated ASGs.

### 2. A joinable AMI

A stock Ubuntu image takes minutes to install containerd and kubeadm, and CA
gives up on a node that has not registered within `--max-node-provision-time`
(15m default) — you get a loop of instances launched and killed.

Launch one instance, install **the same versions your control plane runs**,
and do **not** join it:

```sh
kubectl version -o json | jq -r .serverVersion.gitVersion   # match this
```

Install containerd, kubelet, kubeadm, then:

```sh
sudo systemctl enable kubelet     # enabled, not started — it has nothing to join yet
sudo cloud-init clean --logs      # or the AMI reuses the first boot's instance id
```

Create the AMI from that instance and note the ID.

> Do not build this AMI from a node that has already joined. It carries
> `/etc/kubernetes/pki` and a kubelet identity, so every instance from it
> impersonates the same node and they fight over one Node object.

### 3. A join token that outlives the token

This is the part that breaks months later if you get it wrong. `kubeadm join`
tokens expire after **24 hours**. A node scaling up on day three fails to join,
never registers, and CA eventually terminates it — with no obvious error.

On the control plane:

```sh
kubeadm token create --ttl 0 --print-join-command
```

`--ttl 0` never expires. Store it:

```sh
aws ssm put-parameter \
  --name /k8s/join-command \
  --type SecureString \
  --value "kubeadm join 10.0.1.10:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>" \
  --region us-east-1 --overwrite
```

**This is a permanent credential for joining your cluster.** Anyone who can
read that parameter can add a node. It is scoped to the node role in step 1 and
encrypted at rest, which is the minimum. The alternative — a Lambda that mints
a short-lived token per scale-up — is more work and strictly better; worth
doing if this cluster ever holds anything real.

### 4. Launch template

```sh
cat > /tmp/userdata.sh <<'EOF'
#!/bin/bash
set -euxo pipefail
JOIN=$(aws ssm get-parameter --name /k8s/join-command --with-decryption \
        --region us-east-1 --query Parameter.Value --output text)
eval "$JOIN"
EOF

aws ec2 create-launch-template \
  --launch-template-name k8s-learning-workers \
  --launch-template-data "{
    \"ImageId\": \"<AMI_FROM_STEP_2>\",
    \"InstanceType\": \"t3.medium\",
    \"IamInstanceProfile\": {\"Name\": \"<YOUR_NODE_INSTANCE_PROFILE>\"},
    \"SecurityGroupIds\": [\"sg-05ccb78072f58f40e\"],
    \"UserData\": \"$(base64 -w0 /tmp/userdata.sh)\"
  }"
```

**The security group must be `sg-05ccb78072f58f40e`** — the one carrying the IP
protocol 4 rule Calico's IPIP encapsulation needs. A new node in a group
without it joins, reports Ready, and then silently fails to reach pods on other
nodes. That failure looks like random request timeouts, not a networking error.

### 5. The ASG

```sh
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name k8s-learning-workers \
  --launch-template LaunchTemplateName=k8s-learning-workers,Version='$Latest' \
  --min-size 2 --max-size 6 --desired-capacity 2 \
  --vpc-zone-identifier "<PUBLIC_SUBNET_A>,<PUBLIC_SUBNET_B>" \
  --tags \
    Key=k8s.io/cluster-autoscaler/enabled,Value=true,PropagateAtLaunch=true \
    Key=k8s.io/cluster-autoscaler/learning-cluster,Value=owned,PropagateAtLaunch=true
```

MinSize 2 / MaxSize 6 — the same numbers as `--nodes=2:6:` in the Deployment.
The tags are what the tag-scoped IAM condition in step 1 matches.

New nodes are added to the ALB target groups automatically: the AWS Load
Balancer Controller watches Node objects, and the Ingress uses
`target-type: instance`. Nothing to do there.

### 6. Deploy

```sh
make cluster                      # applies k8s/cluster/$(CLOUD), CLOUD=aws by default
kubectl -n kube-system rollout status deploy/cluster-autoscaler
```

`k8s/cluster/<cloud>/` is the whole convention: `make cluster` applies that
directory and skips with a notice when it does not exist, so a cluster on
another cloud is never handed AWS controllers. `kubectl apply -k k8s/cluster/aws`
does the same thing directly.

## Verifying

The status ConfigMap is the source of truth — it shows what CA believes about
each node group:

```sh
kubectl -n kube-system describe cm cluster-autoscaler-status
kubectl -n kube-system logs -f deploy/cluster-autoscaler
```

Force a scale-up with pods too large to fit:

```sh
kubectl create deploy scale-test --image=registry.k8s.io/pause:3.9 --replicas=20
kubectl set resources deploy/scale-test --requests=cpu=800m
kubectl get pods -w                  # some Pending
kubectl get nodes -w                 # a new node ~3-5 min later
kubectl delete deploy scale-test
```

Scale-down is slower by design — 10 minutes of a node being under-used before
it is considered, per `--scale-down-unneeded-time`.

## What will block scale-down

Expect the cluster to shrink less readily than it grows.

- **PodDisruptionBudgets.** [`k8s/base/web/pdb.yaml`](../k8s/base/web/pdb.yaml)
  uses `minAvailable`, and a PDB that cannot be satisfied stops a drain
  outright. With 2 replicas and `minAvailable: 1` a drain works; at 1 replica
  it cannot, and the node stays forever. `api-core-web` runs 1 replica in prod
  and is patched to `maxUnavailable: 1` — which is what makes it drainable.
- **Pods with no controller.** A bare pod cannot be rescheduled, so its node is
  never removed. Anything from `kubectl run` counts.
- **`safe-to-evict: "false"`.** Set on Cluster Autoscaler itself, deliberately.
- **The control plane.** Not in the ASG, so never a candidate.

## Cost

Six `t3.medium` instances is roughly 3× today's bill at full stretch. MaxSize
is the only thing bounding that, so treat it as a budget control rather than a
capacity guess — CA will use the whole range whenever pods are pending.
