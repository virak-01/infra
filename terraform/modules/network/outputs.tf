# ─── network — outputs ─────────────────────────────────────────────────────────

# ─── outputs ───────────────────────────────────────────────────────────────────
output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Write this into the NetworkPolicy in k8s/components/ingress-alb."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Tagged for internet-facing load balancers."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Where nodes run. Pod IPs come from these ranges under the VPC CNI."
  value       = aws_subnet.private[*].id
}

output "alb_security_group_id" {
  description = "Set as alb.ingress.kubernetes.io/security-groups on the Ingress."
  value       = aws_security_group.alb.id
}

output "azs" {
  value = local.azs
}
