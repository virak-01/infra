# Copy to terraform.tfvars and edit. tfvars files are gitignored.
#
# ============================================================================
# EDIT ssh_allowed_cidrs BEFORE THE FIRST APPLY.
#
# 203.0.113.0/24 is reserved for documentation (RFC 5737) and routes nowhere, so an
# unedited copy FAILS CLOSED — you will not be able to SSH or reach the API server.
# That is deliberate: 0.0.0.0/0 fails OPEN, and the security-group module rejects it.
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
ssh_allowed_cidrs      = ["203.0.113.0/24"] # REPLACE
nodeport_allowed_cidrs = null               # null = same as ssh_allowed_cidrs

# ---------------------------------------------------------------------- compute
# ONE control plane, FIVE workers — all six bootstrap simultaneously.
worker_count = 5

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

# Must outlast the SLOWEST worker's bootstrap. Joins normally land around six minutes
# in; 1h is generous margin for a slow package mirror.
join_token_ttl = "1h"

# --------------------------------------------------------------------------- dns
# null skips the zone and certificate entirely, and the ALB is then reachable by its
# own hostname over HTTP. If you set a domain, also remove the certificate-arn and
# ssl-redirect annotations from k8s/components/ingress-alb, or every request is
# redirected to a certificate that does not match.
domain_name = null
create_zone = false
