# ─── cluster — outputs ─────────────────────────────────────────────────────────

# ─── outputs ───────────────────────────────────────────────────────────────────
output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_data" {
  value     = aws_eks_cluster.this.certificate_authority[0].data
  sensitive = true
}

output "cluster_version" {
  description = "Match the Cluster Autoscaler image minor to this."
  value       = aws_eks_cluster.this.version
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "Issuer without the https:// prefix, the form an IRSA condition key needs."
  value       = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

output "node_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_asg_names" {
  description = "Generated, with a random suffix — which is why the autoscaler should use auto-discovery instead of naming one."
  value = flatten([
    for rs in aws_eks_node_group.this.resources : [
      for asg in rs.autoscaling_groups : asg.name
    ]
  ])
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}
