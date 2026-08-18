# ─── dns — outputs ─────────────────────────────────────────────────────────────

# ─── outputs ───────────────────────────────────────────────────────────────────
output "zone_id" {
  value = local.zone_id
}

output "zone_arn" {
  description = "Scopes the external-dns IAM policy to this zone alone."
  value       = var.create_zone ? aws_route53_zone.this[0].arn : data.aws_route53_zone.existing[0].arn
}

output "certificate_arn" {
  description = <<-EOT
    Write into alb.ingress.kubernetes.io/certificate-arn in
    k8s/components/ingress-alb. Reads from the validation resource, not the
    certificate, so consumers cannot get an unvalidated ARN.
  EOT
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "name_servers" {
  description = "Point the registrar at these when create_zone is true."
  value       = var.create_zone ? aws_route53_zone.this[0].name_servers : []
}

output "domain_name" {
  value = var.domain_name
}
