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

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ----------------------------------------------------------------------- inputs

variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  description = <<-EOT
    Control-plane minor version.

    The Cluster Autoscaler image in the manifests repo MUST match this minor
    (its v1.31.1 speaks to a 1.31 API server). A mismatch fails in subtle ways
    rather than loudly, so the two move together.
  EOT
  type        = string
  default     = "1.31"
}

variable "private_subnet_ids" {
  description = "Nodes and the control-plane ENIs live here."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = <<-EOT
    The Terraform-owned ALB security group. A rule below admits NodePort traffic
    from it, which closes the seam described in modules/network.

    Only takes effect once the Ingress carries
    alb.ingress.kubernetes.io/security-groups with this id.
  EOT
  type        = string
}

variable "node_instance_types" {
  description = <<-EOT
    A LIST, not one type. A managed node group tries them in order when capacity
    in the first is unavailable, which turns a capacity error into a slightly
    different instance.

    t3.medium (2 vCPU / 4 GiB) fits the workload: four Deployments requesting
    200m CPU and 256Mi each.
  EOT
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_min_size" {
  description = "Also the floor the Cluster Autoscaler is given as --nodes=<min>:<max>:<asg>."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = <<-EOT
    The HARD limit. The Cluster Autoscaler can never exceed the node group's max,
    so a CA configured higher silently does less than it claims.
  EOT
  type        = number
  default     = 6
}

variable "node_desired_size" {
  description = "Initial size only — the autoscaler owns it afterwards, which is why it is ignored on subsequent applies."
  type        = number
  default     = 2
}

variable "public_access_cidrs" {
  description = <<-EOT
    Who may reach the Kubernetes API endpoint. 0.0.0.0/0 leaves it open to the
    internet (still authenticated, but reachable). Narrow this to your office or
    VPN range for anything real.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ------------------------------------------------------------- cluster iam role

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

# --------------------------------------------------------------------- cluster

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

# ------------------------------------------------------------- oidc  /  irsa
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

# ---------------------------------------------------------------- node iam role

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

# ------------------------------------------------------------------ node group

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

# The Cluster Autoscaler DISCOVERS groups by these tags when run with
# --node-group-auto-discovery. The manifests repo currently names its ASG
# explicitly (`--nodes=2:6:k8s-learning-workers`), which a managed node group
# cannot satisfy: its ASG name is generated and contains a random suffix. Switch
# the Deployment to auto-discovery, or read the real name from the
# `node_group_asg_names` output below.
resource "aws_autoscaling_group_tag" "autoscaler_enabled" {
  for_each = toset(flatten([
    for rs in aws_eks_node_group.this.resources : [
      for asg in rs.autoscaling_groups : asg.name
    ]
  ]))

  autoscaling_group_name = each.value

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "autoscaler_cluster" {
  for_each = toset(flatten([
    for rs in aws_eks_node_group.this.resources : [
      for asg in rs.autoscaling_groups : asg.name
    ]
  ]))

  autoscaling_group_name = each.value

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

# ------------------------------------------------------ alb  ->  node ports
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

# --------------------------------------------------------------------- addons
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

# ---------------------------------------------------------------------- outputs

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
