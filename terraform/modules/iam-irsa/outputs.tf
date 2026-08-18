# ─── iam-irsa — outputs ────────────────────────────────────────────────────────

# ─── outputs ───────────────────────────────────────────────────────────────────
output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

output "autoscaler_role_arn" {
  value = aws_iam_role.autoscaler.arn
}

output "service_accounts" {
  description = "The namespace/name pairs the trust policies pin. The Helm values must match exactly."
  value       = local.service_accounts
}
