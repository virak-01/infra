# ============================================================================
# THREE SEPARATE ANSWERS. They were one variable until SSH was opened here and
# quietly took the API server and the NodePort range with it.
#
#   ssh_allowed_cidrs       22          who may attempt SSH
#   api_allowed_cidrs       6443        who may talk to kube-apiserver
#   nodeport_allowed_cidrs  30000-32767 who may reach the ingress controller
#
# Null on the latter two still inherits the first, so leaving them null keeps the old
# coupling. Set them.
#
#   curl -s https://checkip.amazonaws.com
# ============================================================================

region       = "us-east-1"
cluster_name = "company-kubeadm"
environment  = "prod"

# ---------------------------------------------------------------------- network
# 10.40 keeps this stack clear of ../infra's 10.20, so both can exist in one account
# and be peered later without renumbering.
vpc_cidr = "10.40.0.0/16"

# Three AZs. With five workers the round-robin spread is 2/2/1, so no single AZ
# failure takes more than two of them.
az_count = 3

# --------------------------------------------------------------------- security
# OPEN, as asked. Note what this does and does not buy: with key_name = null there is
# no key on any instance and sshd rejects passwords, so nobody can log in through this
# port — it admits scanners and fills auth.log, and grants nothing. Narrow it to your
# own address whenever you like; nothing in this stack depends on 22 being reachable.
ssh_allowed_cidrs = ["0.0.0.0/0"]

# OPEN, chosen deliberately. Behind this port is kube-apiserver: authenticated,
# anonymous auth off, but the single control point for the cluster — whoever reaches
# it AND holds admin.conf owns everything running here.
#
# Open because the operator address is an ISP-assigned one that changes, and every
# change silently breaks kubectl and `terraform apply` in ../platform (both talk to
# 6443) until someone re-applies a security-group rule.
#
# To narrow it again, one line — no instances are touched, it is a rule change:
#
#   api_allowed_cidrs = ["<your-address>/32"]   # curl -s https://checkip.amazonaws.com
#
# Better still, put that in local.auto.tfvars, which is gitignored and loaded
# automatically: an operator's address is a property of their machine, not of this
# repository, and committing one locks out everybody else.
api_allowed_cidrs = ["0.0.0.0/0"]

# The ingress controller's NodePort. Open, because this is the edge that serves real
# traffic — there is no ALB in front of it on this stack. Narrow it to a load
# balancer's security group once one exists.
nodeport_allowed_cidrs = ["0.0.0.0/0"]

# ---------------------------------------------------------------------- compute
# ONE control plane, THREE workers — all four bootstrap simultaneously.
#
# TEMPORARILY 3, NOT 5. A new AWS account caps Standard on-demand instances at 16
# vCPU, and five workers do not fit:
#
#   control plane t3.large   2
#   5 x worker    t3.medium  10
#   the ops box              2
#                            -- 14, plus anything else running
#
#   Error: VcpuLimitExceeded: You have requested more vCPU capacity than your
#   current vCPU limit of 16 allows for the instance bucket ...
#
# Shrinking the instance TYPE does not help: every t3 size from nano to large is
# 2 vCPU, so only the count moves the total.
#
# Raise the quota, then put this back to 5:
#
#   aws service-quotas request-service-quota-increase --service-code ec2 \
#     --quota-code L-1216C47A --desired-value 64 --region us-east-1
#
# Going 3 -> 5 later adds two workers and leaves the running three alone.
worker_count = 3

# The control plane is deliberately larger: every kubelet watches its API server and
# every change writes to its etcd, so its load scales with the node count while a
# worker's does not.
instance_type               = "t3.medium"
control_plane_instance_type = "t3.large"
root_volume_size            = 40

# SSH KEY PAIR — null by default, and that is deliberate.
#
# A named key pair that does not exist in your account fails the apply at RunInstances:
#
#   InvalidKeyPair.NotFound: The key pair 'x' does not exist
#
# and it does so AFTER the VPC, subnets and security groups are built — eight minutes
# in, for a value that could have been checked in one. null avoids that entirely.
#
# You are not locked out. ../modules/iam-node attaches AmazonSSMManagedInstanceCore to
# both node roles, so Session Manager reaches any node with no key, no open port 22 and
# no public IP required:
#
#   aws ssm start-session --target $(terraform output -raw control_plane_instance_id)
#
# TO USE SSH INSTEAD, create the pair FIRST and then set the name here:
#
#   aws ec2 create-key-pair --key-name company-kubeadm \
#     --query KeyMaterial --output text > ~/.ssh/company-kubeadm.pem
#   chmod 600 ~/.ssh/company-kubeadm.pem
#
# Terraform does not create it: a key pair resource puts the PRIVATE KEY in state.
key_name = null

# ------------------------------------------------------------------- kubernetes
kubernetes_version = "1.31"

# MUST NOT overlap vpc_cidr. Also Calico's default pool, so the pinned manifest needs
# no patching.
pod_cidr = "192.168.0.0/16"

cni_manifest_url = "https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml"

# Must outlast every RETRY, not just the first attempt. Joins normally land around six
# minutes in, which makes 1h look generous — but the bootstrap is a systemd unit that
# retries every minute until it succeeds, so a worker blocked on a slow control plane
# can still be trying an hour later. It then fetches an expired token, fails, and
# retries forever against a credential that can never work again. A short TTL turns a
# temporary problem into a permanent one.
join_token_ttl = "24h"

# --------------------------------------------------------------------------- dns
# null skips the zone and certificate entirely, and the ALB is then reachable by its
# own hostname over HTTP. If you set a domain, also remove the certificate-arn and
# ssl-redirect annotations from k8s/components/ingress-alb, or every request is
# redirected to a certificate that does not match.
domain_name = null
create_zone = false
