# ─── network — inputs ──────────────────────────────────────────────────────────

# ─── inputs ────────────────────────────────────────────────────────────────────
variable "name" {
  description = "Name prefix for every resource here."
  type        = string
}

variable "cluster_name" {
  description = <<-EOT
    EKS cluster name. Used only for the `kubernetes.io/cluster/<name>` subnet tag.
    Optional for the load balancer controller since Kubernetes 1.19, kept because
    it is still what most troubleshooting docs tell you to check.
  EOT
  type        = string
}

variable "vpc_cidr" {
  description = <<-EOT
    VPC CIDR. This value ALSO has to be written into the cluster manifests: the
    NetworkPolicy in k8s/components/ingress-alb allows node-sourced traffic from
    this range, because an ALB with instance targets arrives from a node address.
    It is exposed as the `vpc_cidr` output for exactly that reason.
  EOT
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be valid CIDR notation, e.g. 10.20.0.0/16."
  }
}

variable "az_count" {
  description = <<-EOT
    Availability Zones to spread across. An ALB requires at least two, even for a
    single-node cluster — it will not provision in one AZ.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6 (an ALB needs at least 2)."
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Create NAT gateways so the private subnets have outbound internet.

    TRUE for EKS, which is why it defaults that way: nodes there sit in private
    subnets and cannot pull an image or reach the control plane without it.

    FALSE for the kubeadm path (../../infra-kubeadm), where nodes sit in PUBLIC
    subnets with public IPs and reach the internet through the internet gateway
    directly. Roughly USD 32/month for a gateway nothing routes through.
  EOT
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = <<-EOT
    true  — one NAT gateway shared by every private subnet (~$32/mo, one AZ of
            egress is a single point of failure).
    false — one per AZ (~$32/mo each, survives an AZ loss).

    true is the right default for a learning platform; flip it before anything
    depends on private-subnet egress staying up.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged onto everything."
  type        = map(string)
  default     = {}
}
