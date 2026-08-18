# THE KUBEADM STACK — a control plane and N workers on EC2, all bootstrapping at once.
#
# The alternative to ../infra, which builds the same platform on EKS. Both exist
# because they answer different questions:
#
#   ../infra          AWS runs the control plane. Two compute resources, no bootstrap,
#                     no join token, IRSA for controller permissions. ~USD 73/month for
#                     the control plane you never see.
#   this stack        You run the control plane. Six instances, three bootstrap
#                     scripts, a join token to keep out of git — and no control-plane
#                     charge. This is what the cluster in k8s/ runs on today.
#
# They SHARE the network, registry and dns modules and keep SEPARATE state, so both can
# exist in one account without fighting. Pick one per cluster; running both means two
# clusters and two bills.
#
# ---------------------------------------------------------------------------------
# HOW SIX MACHINES INSTALL KUBERNETES SIMULTANEOUSLY
#
# All six instances boot in parallel — Terraform issues the RunInstances calls at once
# and cloud-init starts immediately on each. The workers therefore reach their join
# step minutes BEFORE the control plane has finished `kubeadm init`, and no Terraform
# construct can fix that: `depends_on` orders API calls, not software inside an
# instance.
#
#   t+0    six instances boot in parallel
#   t+2m   every node: containerd, kubeadm, kubelet installed concurrently
#   t+3m   control plane: kubeadm init
#   t+4m   control plane: Calico applied
#   t+5m   control plane: kubeadm token create --ttl  ->  SSM SecureString
#          workers 1..N: polling that parameter every 15s since t+2m
#   t+6m   all workers join
#
# Each worker polls independently with its own 20-minute deadline, so five workers do
# not queue behind each other. Five concurrent `kubeadm join` calls against one API
# server are fine — each performs its own TLS bootstrap and CSR, which is exactly what
# a bootstrap token is for.
#
# The token never appears in git, in state, or in user-data. See ../modules/iam-node.

# ─── inputs ────────────────────────────────────────────────────────────────────
variable "region" {
  description = "AWS region for every resource."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Cluster name. Also the resource name prefix and the kubernetes.io/cluster tag value."
  type        = string
  default     = "company-kubeadm"
}

variable "environment" {
  description = <<-EOT
    Environment label. Also the SSM path segment for the join command
    (/k8s/<environment>/join-command), which is what stops two clusters in one account
    from reading each other's token.
  EOT
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = <<-EOT
    VPC CIDR.

    ALSO GOES INTO THE MANIFESTS: the NetworkPolicy in k8s/components/ingress-alb
    admits node-sourced traffic from this range, because an ALB with instance targets
    arrives from a node address. Exposed as the `vpc_cidr` output for that reason —
    ./script/sync-manifests.sh carries it across.

    Distinct from ../infra's default so the two stacks can coexist and be peered later
    without renumbering.
  EOT
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Availability Zones to spread across. An ALB needs at least two."
  type        = number
  default     = 3
}

variable "worker_count" {
  description = <<-EOT
    Number of worker nodes. All of them bootstrap in parallel with the control plane.

    Five is the shipped default for this stack. The practical ceiling for a SINGLE
    control plane is around ten — beyond that the API server and etcd on one instance
    become the limit, and the answer is a second control-plane node rather than a
    bigger one. The etcd peer rules (2379-2380) in ../modules/security-group are
    already in place for that.
  EOT
  type        = number
  default     = 5
}

variable "instance_type" {
  description = "Worker instance type."
  type        = string
  default     = "t3.medium"
}

variable "control_plane_instance_type" {
  description = <<-EOT
    Control-plane instance type.

    Sized ABOVE the workers on purpose. Every kubelet watches the API server and every
    change writes to etcd, so the control plane carries load proportional to the node
    count while a worker carries only its own pods. Five workers behind a t3.small is
    where clusters start timing out for no visible reason.

    kubeadm's preflight check also requires at least 2 vCPU here.
  EOT
  type        = string
  default     = "t3.large"
}

variable "root_volume_size" {
  description = "Root volume GiB per node. etcd, container images and logs share it on the control plane."
  type        = number
  default     = 40
}

variable "key_name" {
  description = <<-EOT
    Name of an EXISTING EC2 key pair. Null disables SSH keys entirely, which works
    because Session Manager is enabled on both roles.

    Not created by Terraform: that would put the private key in state.
  EOT
  type        = string
  default     = null
}

variable "ssh_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach SSH (22).

    NO DEFAULT. A default is either 0.0.0.0/0, which silently exposes SSH to the
    internet, or someone else's address.

    Also the fallback for api_allowed_cidrs and nodeport_allowed_cidrs when those are
    null, so widening this widens them too unless they are set explicitly.

    Find yours:  curl -s https://checkip.amazonaws.com
  EOT
  type        = list(string)
}

variable "api_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the Kubernetes API (6443). Null inherits ssh_allowed_cidrs.

    Worth setting on its own: kubectl needs this open from wherever you run it, which
    is rarely the same answer as who should reach SSH. This is also the port that
    terraform/platform talks to — its providers read the cluster at PLAN time, so an
    unreachable API fails the plan, not the apply.
  EOT
  type        = list(string)
  default     = null
}

variable "nodeport_allowed_cidrs" {
  description = "CIDRs allowed to reach 30000-32767. Null falls back to ssh_allowed_cidrs, so nothing is public until stated."
  type        = list(string)
  default     = null
}

variable "kubernetes_version" {
  description = "Kubernetes MINOR version, e.g. \"1.31\". Selects the pkgs.k8s.io repository as well as the cluster version."
  type        = string
  default     = "1.31"
}

variable "pod_cidr" {
  description = "Pod network CIDR. MUST NOT overlap vpc_cidr, and must match the CNI's expected pool."
  type        = string
  default     = "192.168.0.0/16"
}

variable "cni_manifest_url" {
  description = "Pinned CNI manifest applied after kubeadm init. Nodes stay NotReady until a CNI is installed."
  type        = string
  default     = "https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml"
}

variable "join_token_ttl" {
  description = <<-EOT
    Bootstrap token lifetime, as a Go duration.

    MUST COVER THE SLOWEST WORKER. Joins normally happen around six minutes in, so 1h
    leaves generous margin for a slow package mirror. Adding a node later mints a fresh
    token rather than relying on this one still being valid.
  EOT
  type        = string
  default     = "1h"
}

variable "domain_name" {
  description = "Set to null to skip the hosted zone and certificate entirely."
  type        = string
  default     = null
}

variable "create_zone" {
  description = "Create the hosted zone rather than looking one up by name."
  type        = bool
  default     = false
}

# ─── shared ────────────────────────────────────────────────────────────────────
locals {
  name_prefix = "${var.cluster_name}-${var.environment}"

  # Namespaced per environment so two clusters in one account cannot read or overwrite
  # each other's join command — the IAM policies are scoped to this exact path.
  join_command_parameter_name = "/k8s/${var.environment}/join-command"

  common_tags = {
    Environment = var.environment
    Cluster     = var.cluster_name
  }
}

module "network" {
  source = "../modules/network"

  name         = local.name_prefix
  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr
  az_count     = var.az_count

  # NO NAT GATEWAY. Nodes sit in the PUBLIC subnets with public IPs and reach the
  # internet through the internet gateway, so nothing routes through a NAT — it would
  # be roughly USD 32/month for an unused resource. The private subnets are still
  # created, tagged and routable within the VPC, ready for a database or for moving
  # nodes off the public network later.
  enable_nat_gateway = false

  tags = local.common_tags
}

module "registry" {
  source = "../modules/registry"

  repositories = ["website", "core", "auth"]
  tags         = local.common_tags
}

module "dns" {
  source = "../modules/dns"
  count  = var.domain_name != null ? 1 : 0

  domain_name = var.domain_name
  create_zone = var.create_zone
  tags        = local.common_tags
}

# ─── kubeadm ───────────────────────────────────────────────────────────────────
module "security_group" {
  source = "../modules/security-group"

  name_prefix            = local.name_prefix
  vpc_id                 = module.network.vpc_id
  ssh_allowed_cidrs      = var.ssh_allowed_cidrs
  api_allowed_cidrs      = var.api_allowed_cidrs
  nodeport_allowed_cidrs = var.nodeport_allowed_cidrs
  pod_cidr               = var.pod_cidr

  tags = local.common_tags
}

# THE JOIN TOKEN NEVER TOUCHES GIT. This grants the control plane write access to one
# SSM parameter and the workers read access to the same one — nothing else, in either
# direction. The control plane cannot read back what it wrote; a worker cannot publish.
module "iam_node" {
  source = "../modules/iam-node"

  name_prefix                 = local.name_prefix
  join_command_parameter_name = local.join_command_parameter_name
  enable_ssm_session_manager  = true

  tags = local.common_tags
}

module "ec2" {
  source = "../modules/ec2"

  name_prefix  = local.name_prefix
  cluster_name = var.cluster_name
  environment  = var.environment

  instance_type               = var.instance_type
  control_plane_instance_type = var.control_plane_instance_type
  root_volume_size            = var.root_volume_size
  key_name                    = var.key_name

  # Public subnets, round-robin. With three subnets and five workers the spread is
  # 2/2/1, so no single AZ failure takes more than two of them.
  subnet_ids          = module.network.public_subnet_ids
  associate_public_ip = true

  control_plane_security_group_id = module.security_group.control_plane_security_group_id
  worker_security_group_id        = module.security_group.worker_security_group_id
  control_plane_instance_profile  = module.iam_node.control_plane_instance_profile_name
  worker_instance_profile         = module.iam_node.worker_instance_profile_name

  worker_count                = var.worker_count
  kubernetes_version          = var.kubernetes_version
  pod_cidr                    = var.pod_cidr
  cni_manifest_url            = var.cni_manifest_url
  join_command_parameter_name = local.join_command_parameter_name
  join_token_ttl              = var.join_token_ttl

  tags = local.common_tags
}

# ─── outputs ───────────────────────────────────────────────────────────────────
output "cluster_name" {
  value = var.cluster_name
}

output "region" {
  value = var.region
}

output "control_plane_public_ip" {
  description = "SSH here, and point kubectl here."
  value       = module.ec2.control_plane_public_ip
}

output "control_plane_instance_id" {
  description = "For Session Manager: aws ssm start-session --target <id>"
  value       = module.ec2.control_plane_id
}

output "worker_public_ips" {
  description = "Ingress NodePort traffic arrives at these addresses."
  value       = module.ec2.worker_public_ips
}

output "worker_count" {
  value = var.worker_count
}

output "join_command_parameter_name" {
  description = "SSM path holding the join command. The VALUE is never an output — that would put a live credential in state and in any CI log that prints outputs."
  value       = module.ec2.join_command_parameter_name
}

output "vpc_cidr" {
  description = "Write into the NetworkPolicy ipBlock in k8s/components/ingress-alb."
  value       = module.network.vpc_cidr
}

output "registry_host" {
  description = "Replaces the ECR host in both overlays."
  value       = module.registry.registry_host
}

output "certificate_arn" {
  value = var.domain_name != null ? module.dns[0].certificate_arn : null
}

output "alb_security_group_id" {
  value = module.network.alb_security_group_id
}

output "ssh_command" {
  value = var.key_name != null ? format(
    "ssh -i ~/.ssh/%s.pem ubuntu@%s", var.key_name, module.ec2.control_plane_public_ip
  ) : "no key_name set — use: aws ssm start-session --target ${module.ec2.control_plane_id}"
}

# Consumed by ./script/sync-manifests.sh, matching ../infra's output of the same name
# so the script works against either stack.
output "kustomize_values" {
  value = {
    registry_host         = module.registry.registry_host
    certificate_arn       = var.domain_name != null ? module.dns[0].certificate_arn : null
    vpc_cidr              = module.network.vpc_cidr
    alb_security_group_id = module.network.alb_security_group_id
    region                = var.region
    cluster_name          = var.cluster_name
  }
}
