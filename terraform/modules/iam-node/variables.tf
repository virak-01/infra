variable "name_prefix" {
  description = "Prefix for role and policy names, normally \"<project>-<environment>\"."
  type        = string
}

variable "join_command_parameter_name" {
  description = <<-EOT
    SSM Parameter Store path holding the kubeadm join command, for example
    /k8s/dev/join-command.

    Taken as a NAME rather than an ARN on purpose. The ARN is constructed below
    from the caller's account and region, which avoids a dependency cycle: the ec2
    module creates the parameter and also needs these roles, so referencing the
    parameter resource from here would make the two modules depend on each other.
  EOT
  type        = string

  validation {
    condition     = startswith(var.join_command_parameter_name, "/")
    error_message = "The parameter name must start with / — an ARN built from a relative name will not match."
  }
}

variable "enable_ssm_session_manager" {
  description = <<-EOT
    Attach AmazonSSMManagedInstanceCore, which lets you open a root shell on a node
    through Session Manager with no SSH key, no port 22 and no public IP.

    Enabled by default: it is the difference between needing SSH open to the world
    and needing no inbound access at all. The trade is that the managed policy is
    broader than the rest of this module — it grants the ssmmessages and
    ec2messages channels account-wide, because those APIs cannot be
    resource-scoped. Set false for the strictest possible node role, and rely on
    SSH instead.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags merged onto every IAM resource here."
  type        = map(string)
  default     = {}
}
