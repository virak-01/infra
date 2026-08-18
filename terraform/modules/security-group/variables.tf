variable "name_prefix" {
  description = "Prefix for security group names, normally \"<project>-<environment>\"."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = <<-EOT
    CIDRs permitted to reach TCP 22 and the Kubernetes API on 6443.

    NO DEFAULT ON PURPOSE. A default of 0.0.0.0/0 fails open — every environment
    would silently expose SSH and the API server to the internet. Each environment
    must state its own answer, and the shipped tfvars use a documentation range so
    an unedited copy fails CLOSED (you cannot connect) rather than wide open.

    Find your address with:  curl -s https://checkip.amazonaws.com
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs must not be empty — you would lock yourself out."
  }

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 exposes SSH and the Kubernetes API to the internet. Narrow it to your own address, or edit this module if you accept the risk."
  }
}

variable "nodeport_allowed_cidrs" {
  description = <<-EOT
    CIDRs permitted to reach the NodePort range, 30000-32767. This is how traffic
    reaches an ingress controller published as a NodePort Service.

    Defaults to the SSH list so nothing is public until stated. Widen it to
    ["0.0.0.0/0"] once an ingress controller is meant to serve real users, or point
    it at a load balancer's security group instead.
  EOT
  type        = list(string)
  default     = null
}

variable "pod_cidr" {
  description = <<-EOT
    Pod network CIDR, matching --pod-network-cidr in the control-plane bootstrap.

    Needed here because an overlay CNI encapsulates pod traffic and the nodes must
    accept it. Must NOT overlap the VPC CIDR.
  EOT
  type        = string
  default     = "192.168.0.0/16"
}

variable "tags" {
  description = "Tags merged onto both security groups."
  type        = map(string)
  default     = {}
}
