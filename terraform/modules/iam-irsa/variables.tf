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

    NOT written by hand: it is ~180 statements with specific conditions, revised
    per controller release, and a subtly wrong copy fails at ALB-creation time
    with an AccessDenied that names an action you did not know it needed. Fetch
    the pinned upstream copy first:

      ./script/fetch-policies.sh

    A missing file fails the plan immediately, which is the right failure.
  EOT
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
