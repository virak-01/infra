variable "name_prefix" {
  description = "Prefix for instance names, normally \"<project>-<environment>\"."
  type        = string
}

variable "cluster_name" {
  description = "Kubernetes cluster name, applied as a tag on every node."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, production). Tagged on every resource."
  type        = string
}

# ─── image ─────────────────────────────────────────────────────────────────────
variable "ami_id" {
  description = <<-EOT
    AMI for every node. Leave null to look up the latest Canonical Ubuntu 22.04 LTS
    image for the current region.

    The lookup is the sensible default because an AMI ID is region-specific — a
    hard-coded one makes the configuration silently wrong in any other region. Pin
    a value for reproducible builds, since "latest" changes under you and a new
    apply would replace running nodes.
  EOT
  type        = string
  default     = null
}

variable "instance_type" {
  description = <<-EOT
    Instance type for all nodes.

    A control plane needs at least 2 vCPU — kubeadm's preflight check fails below
    that — so t3.small (2 vCPU / 2 GiB) is the practical floor and t3.medium
    (2 vCPU / 4 GiB) the comfortable one.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "control_plane_instance_type" {
  description = "Override the instance type for the control plane only. Null uses instance_type."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = <<-EOT
    Root volume size in GiB. Container images, etcd and logs all live here; below
    about 20 GiB the kubelet starts evicting pods under disk pressure.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size >= 20
    error_message = "Use at least 20 GiB — the kubelet evicts pods under disk pressure below that."
  }
}

variable "key_name" {
  description = <<-EOT
    Name of an EXISTING EC2 key pair for SSH. Null disables SSH key injection
    entirely, which is viable when Session Manager is enabled in the IAM module.

    The key pair itself is not created here on purpose: Terraform creating a key
    pair means the private key lands in state in cleartext.
  EOT
  type        = string
  default     = null
}

# ─── placement ─────────────────────────────────────────────────────────────────
variable "subnet_ids" {
  description = <<-EOT
    Subnets to place nodes in, round-robin. Public subnets by default so nodes are
    reachable for SSH and can pull packages during bootstrap without a NAT gateway.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one subnet is required."
  }
}

variable "associate_public_ip" {
  description = "Give nodes a public IP. Required in a public subnet with no NAT gateway, or bootstrap cannot reach the package repositories."
  type        = bool
  default     = true
}

variable "control_plane_security_group_id" {
  description = "Security group for the control-plane instance."
  type        = string
}

variable "worker_security_group_id" {
  description = "Security group for worker instances."
  type        = string
}

variable "control_plane_instance_profile" {
  description = "IAM instance profile granting SSM write access for the join command."
  type        = string
}

variable "worker_instance_profile" {
  description = "IAM instance profile granting SSM read access for the join command."
  type        = string
}

# ─── kubernetes ────────────────────────────────────────────────────────────────
variable "worker_count" {
  description = "Number of worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 10
    error_message = "worker_count must be between 1 and 10."
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes MINOR version, e.g. "1.31" — not a patch version.

    The minor is part of the pkgs.k8s.io repository URL, so it selects the package
    repository as well as the cluster version.
  EOT
  type        = string
  default     = "1.31"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "Use a minor version like \"1.31\", not a patch version like \"1.31.4\"."
  }
}

variable "pod_cidr" {
  description = <<-EOT
    Pod network CIDR, passed to kubeadm as --pod-network-cidr.

    MUST NOT OVERLAP THE VPC CIDR, or pod addresses collide with node addresses and
    routing breaks in ways that look intermittent. The default 192.168.0.0/16 is
    also what the Calico manifest expects.
  EOT
  type        = string
  default     = "192.168.0.0/16"
}

variable "cni_manifest_url" {
  description = <<-EOT
    CNI manifest applied by the control plane after init.

    Pinned to a version rather than "latest": a CNI that changes under a running
    cluster is not a change anyone wants to discover by surprise. Calico's default
    IP pool is 192.168.0.0/16, matching pod_cidr above.
  EOT
  type        = string
  default     = "https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml"
}

variable "join_command_parameter_name" {
  description = "SSM parameter path where the control plane publishes the join command and workers read it."
  type        = string
}

variable "join_token_ttl" {
  description = <<-EOT
    Lifetime of the bootstrap token, as a Go duration.

    Short on purpose: a token is a credential that enrols a node, so it should stop
    working long before anyone finds the parameter. 24h covers a normal apply plus
    troubleshooting; scripts/join-worker.sh mints a fresh one for later additions.
  EOT
  type        = string
  default     = "24h"
}

variable "node_user" {
  description = "Login user on the AMI, which receives a copy of the kubeconfig. \"ubuntu\" on Canonical images."
  type        = string
  default     = "ubuntu"
}

variable "tags" {
  description = "Tags merged onto every resource here."
  type        = map(string)
  default     = {}
}
