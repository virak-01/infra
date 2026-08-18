# ─── cluster — inputs ──────────────────────────────────────────────────────────

# ─── inputs ────────────────────────────────────────────────────────────────────
variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  description = <<-EOT
    Control-plane minor version.

    The Cluster Autoscaler image in the manifests repo MUST match this minor
    (its v1.31.1 speaks to a 1.31 API server). A mismatch fails in subtle ways
    rather than loudly, so the two move together.
  EOT
  type        = string
  default     = "1.31"
}

variable "private_subnet_ids" {
  description = "Nodes and the control-plane ENIs live here."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = <<-EOT
    The Terraform-owned ALB security group. A rule below admits NodePort traffic
    from it, which closes the seam described in modules/network.

    Only takes effect once the Ingress carries
    alb.ingress.kubernetes.io/security-groups with this id.
  EOT
  type        = string
}

variable "node_instance_types" {
  description = <<-EOT
    A LIST, not one type. A managed node group tries them in order when capacity
    in the first is unavailable, which turns a capacity error into a slightly
    different instance.

    t3.medium (2 vCPU / 4 GiB) fits the workload: four Deployments requesting
    200m CPU and 256Mi each.
  EOT
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_min_size" {
  description = "Also the floor the Cluster Autoscaler is given as --nodes=<min>:<max>:<asg>."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = <<-EOT
    The HARD limit. The Cluster Autoscaler can never exceed the node group's max,
    so a CA configured higher silently does less than it claims.
  EOT
  type        = number
  default     = 6
}

variable "node_desired_size" {
  description = "Initial size only — the autoscaler owns it afterwards, which is why it is ignored on subsequent applies."
  type        = number
  default     = 2
}

variable "public_access_cidrs" {
  description = <<-EOT
    Who may reach the Kubernetes API endpoint. 0.0.0.0/0 leaves it open to the
    internet (still authenticated, but reachable). Narrow this to your office or
    VPN range for anything real.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
