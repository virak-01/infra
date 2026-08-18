# ─── EKS managed add-ons, pinned rather than left to cluster defaults. ─────────

# ─── addons ────────────────────────────────────────────────────────────────────
#
# Pinned as managed addons rather than left to the cluster defaults, so a version
# bump is a reviewed change. `most_recent` deliberately unset: an addon that
# upgrades itself changes the CNI under a running cluster.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = var.tags
}

# After the node group: CoreDNS pods have no node to schedule on before it exists
# and the addon reports degraded while it waits.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = var.tags

  depends_on = [aws_eks_node_group.this]
}
