# The EKS cluster and one managed node group.
#
# This is the whole compute layer, and that is the point of choosing EKS. The
# kubeadm equivalent was five resources plus a manual step: a control-plane
# instance, `kubeadm token create`, an SSM parameter holding its output, a launch
# template whose user-data reads it, and an ASG. Two of those five had values
# Terraform could not own — a token minted by a running control plane is not
# expressible in HCL.
#
# What managed node groups delete outright:
#   * the SSM join-command seam — nodes join via the EKS API
#   * the Cluster Autoscaler's control-plane nodeSelector, which can never
#     schedule on EKS (there are no control-plane nodes in your cluster) and
#     leaves the pod Pending forever with no event naming the cause
#   * the ECR pull-secret CronJob — the node role handles pulls

# ─── cluster iam role ──────────────────────────────────────────────────────────
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ─── cluster ───────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "cluster" {
  # EKS writes to this exact name. Creating it here rather than letting EKS do it
  # implicitly is what allows a retention period — the implicit group never
  # expires and bills forever.
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    # Private subnets only. The control plane places its ENIs here; the ALB lives
    # in the public subnets and reaches nodes across the VPC.
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  # `audit` and `authenticator` are the two that matter after an incident: who
  # called what, and who authenticated. Without them there is no record at all.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # API is the modern path and avoids the aws-auth ConfigMap entirely — that
  # ConfigMap has no Terraform-safe representation and a bad edit locks everyone
  # out of the cluster irreversibly.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(var.tags, { Name = var.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ─── oidc  /  irsa ─────────────────────────────────────────────────────────────
#
# The foundation of every IRSA role in modules/iam-irsa. Without this provider a
# ServiceAccount token is just a JWT AWS does not trust, and every controller
# falls back to the node role — which is the permission model EKS is meant to
# replace.

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# ─── node iam role ─────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# The Cluster Autoscaler DISCOVERS groups by these tags when run with
# --node-group-auto-discovery. The manifests repo currently names its ASG
# explicitly (`--nodes=2:6:k8s-learning-workers`), which a managed node group
# cannot satisfy: its ASG name is generated and contains a random suffix. Switch
# the Deployment to auto-discovery, or read the real name from the
# `node_group_asg_names` output below.
#
# COUNT, NOT for_each — and the difference is not stylistic.
#
# `for_each` keys become resource addresses, so Terraform must know the full key set
# during PLAN. The ASG name does not exist until the node group has been created, so a
# for_each over it fails before anything is applied:
#
#   Invalid for_each argument … is a list of object, known only after apply
#
# `count` needs only a known LENGTH, and the length here is a constant: a managed node
# group creates exactly one Auto Scaling group. The name is still unknown at plan time,
# but that is fine — it is an attribute, not an address.
#
# The literal [0][0] indexing is safe for the same reason: one node group, one ASG.
# Adding a second node group means revisiting this, and a `count` of 1 makes that
# obvious in a way a silently-empty for_each would not.
locals {
  node_group_asg_name = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name
}
