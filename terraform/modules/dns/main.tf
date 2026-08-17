# Hosted zone and certificate — and deliberately NO A or ALIAS records.
#
# THE CYCLE this avoids: an ALIAS record needs the ALB's hostname; the ALB does
# not exist until the Ingress is applied; the Ingress is applied after Terraform.
# Owning the records here would need a second apply stage reading the ALB back
# with `data "aws_lb"`.
#
# Instead external-dns runs in the cluster and writes records from Ingress hosts
# (see ../../platform). One apply, and DNS follows a hostname change in an overlay
# automatically. The records live outside Terraform state, which is the trade:
# `terraform destroy` leaves them behind, so external-dns is configured with
# policy=sync so it cleans up its own.
#
# The certificate has no such problem — ACM validation records are ordinary CNAMEs
# that depend on nothing in the cluster, so those ARE owned here.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

variable "domain_name" {
  description = "Apex domain, e.g. devops-selft-learning.xyz."
  type        = string
}

variable "create_zone" {
  description = <<-EOT
    true  — create the hosted zone here. You must then point the registrar at the
            zone's name servers (see the `name_servers` output) or nothing
            resolves and ACM validation never completes.
    false — look up an existing zone by name.
  EOT
  type        = bool
  default     = false
}

variable "subject_alternative_names" {
  description = <<-EOT
    Extra names on the certificate. The wildcard covers uat., uat-api. and api.
    in one certificate, which is what lets UAT and prod share it.

    A wildcard matches ONE label: *.example.com covers uat.example.com but not
    a.b.example.com.
  EOT
  type        = list(string)
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  sans = var.subject_alternative_names != null ? var.subject_alternative_names : ["*.${var.domain_name}"]
}

# ------------------------------------------------------------------------- zone

resource "aws_route53_zone" "this" {
  count = var.create_zone ? 1 : 0
  name  = var.domain_name
  tags  = merge(var.tags, { Name = var.domain_name })
}

data "aws_route53_zone" "existing" {
  count        = var.create_zone ? 0 : 1
  name         = var.domain_name
  private_zone = false
}

locals {
  zone_id = var.create_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.existing[0].zone_id
}

# ------------------------------------------------------------------ certificate

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

# ---------------------------------------------------------------------- outputs

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
