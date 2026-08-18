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
    CIDRs permitted to reach TCP 22.

    ONLY 22. This used to gate the Kubernetes API as well, which meant opening SSH
    silently opened 6443 — see api_allowed_cidrs below, which now takes that job and
    falls back to this list when unset, so existing configurations behave as before.

    NO DEFAULT ON PURPOSE. A default of 0.0.0.0/0 fails open. The shipped tfvars use
    a documentation range so an unedited copy fails CLOSED (you cannot connect)
    rather than wide open.

    0.0.0.0/0 IS ACCEPTED but is a real decision, not a shortcut. Note that with
    key_name = null there is no key on the instances and sshd rejects passwords, so
    an open 22 admits nobody — it collects bot traffic and auth-log noise and grants
    nothing. Session Manager is the keyless way in.

    Find your address with:  curl -s https://checkip.amazonaws.com
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs must not be empty — you would lock yourself out."
  }
}

variable "api_allowed_cidrs" {
  description = <<-EOT
    CIDRs permitted to reach the Kubernetes API on 6443.

    Null falls back to ssh_allowed_cidrs, which is what this module did when the two
    shared one variable. Set it explicitly to keep the API narrow while SSH is wide —
    the reason the two were separated.

    WHAT IS BEHIND THIS PORT: kube-apiserver, which is authenticated (anonymous auth
    is off) but is also the single control point for the whole cluster. Whoever holds
    admin.conf and can reach this port owns everything running here.

    kubectl from your machine needs your address in this list. If `kubectl get nodes`
    HANGS rather than erroring, this is why.
  EOT
  type        = list(string)
  default     = null
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
