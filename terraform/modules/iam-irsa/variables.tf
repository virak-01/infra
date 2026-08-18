# ─── iam-irsa — inputs ─────────────────────────────────────────────────────────

# ─── inputs ────────────────────────────────────────────────────────────────────
variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  description = "Issuer with no https:// prefix."
  type        = string
}

variable "route53_zone_arn" {
  description = <<-EOT
    Scopes external-dns to one zone. Passing null grants it every zone in the
    account, which is the difference between a DNS controller and an account-wide
    DNS rewrite capability.
  EOT
  type        = string
  default     = null
}

variable "alb_controller_policy_json" {
  description = <<-EOT
    Path to the AWS-published load balancer controller IAM policy.

    NULL uses this module's own policies/alb-controller.json, resolved with
    path.module so it is correct no matter which directory terraform runs from. A
    plain relative path here would be resolved against the ROOT module's directory,
    which is why the earlier default broke the moment anything ran from elsewhere.

    THE FILE IS NOT IN GIT. It is upstream's, pinned, and fetched once:

      ./script/fetch-policies.sh

    Without it the plan fails at `file(...)` with "Invalid function argument" —
    Terraform cannot even build the graph. That is deliberate: it is better than
    attaching an empty or hand-copied policy, which fails later at ALB-creation time
    with an AccessDenied naming an action you did not know the controller needed.
  EOT
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
