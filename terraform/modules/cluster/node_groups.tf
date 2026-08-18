# ─── The managed node group, its IAM role, and the ALB -> NodePort rule. ───────

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",

    # THE ONE THAT REPLACES THE CronJob. The kubelet's ECR credential provider
    # uses this to mint a token per pull — nothing stored, nothing to expire.
    # Drop `registry-ecr` from the overlays once this cluster is the target.
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",

    # Lets you open a shell on a node without SSH, a bastion, or port 22 open.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ─── node group ────────────────────────────────────────────────────────────────
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-workers"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  # Replace nodes one at a time, never taking the group below its minimum.
  update_config {
    max_unavailable = 1
  }

  # THE AUTOSCALER OWNS desired_size. Without this, every apply resets the group
  # to var.node_desired_size — scaling the cluster back down during exactly the
  # traffic spike that grew it. Same reasoning as ignoring /spec/replicas in the
  # Argo CD Applications.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-workers" })

  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_autoscaling_group_tag" "autoscaler_enabled" {
  count = 1

  autoscaling_group_name = local.node_group_asg_name

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "autoscaler_cluster" {
  count = 1

  autoscaling_group_name = local.node_group_asg_name

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

# ─── alb  ->  node ports ───────────────────────────────────────────────────────
#
# Closes the seam. The node group's own security group is created by EKS; this
# adds one rule to it admitting the NodePort range from the ALB group Terraform
# owns. Source-group rather than CIDR is what makes it a real boundary: the ALB
# re-originates connections from its own interfaces, so the node sees that group
# and can refuse everything else.

resource "aws_vpc_security_group_ingress_rule" "nodeports_from_alb" {
  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description                  = "NodePort range from the ingress ALB only"
  referenced_security_group_id = var.alb_security_group_id
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"
}
