# ─── The ACM certificate and its DNS validation records. ───────────────────────

# ─── certificate ───────────────────────────────────────────────────────────────
resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = local.sans
  validation_method         = "DNS"

  # Replacing a certificate in use by a live ALB listener would drop TLS during
  # the gap. Create the new one, let the listener move, then remove the old.
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = var.domain_name })
}

# One record per distinct validation CNAME. Apex and wildcard usually validate
# with the SAME record, so the for-loop is keyed by domain_name to collapse the
# duplicate — without that key, two resources fight over one record.
resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks the apply until ACM reports ISSUED. Without this, a certificate ARN can
# be handed to the manifests while still PENDING_VALIDATION — the ALB then
# refuses the listener and the failure surfaces on the Ingress, far from here.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]

  timeouts {
    create = "20m"
  }
}
