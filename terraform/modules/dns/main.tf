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

locals {
  sans = var.subject_alternative_names != null ? var.subject_alternative_names : ["*.${var.domain_name}"]
}

# ─── zone ──────────────────────────────────────────────────────────────────────
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
