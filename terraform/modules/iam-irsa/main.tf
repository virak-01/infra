# IRSA roles for the three in-cluster controllers.
#
# IRSA is the reason EKS is worth the control-plane cost. On the kubeadm cluster
# these permissions had to land on the NODE role, which means every pod on the
# node could use them through the instance metadata endpoint — the reason
# k8s/base/networkpolicy-egress.yaml blocks 169.254.169.254 in the first place.
# Here each controller gets its own role, assumable only by its own
# ServiceAccount, and no pod can reach permissions it was not granted.
#
# WHAT IS NOT HERE: the `ecr-pull-refresher` IAM user. On EKS the node role pulls
# images directly, so the static access key and the CronJob that used it are both
# gone. That removes an unrotated long-lived credential from the platform.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

# ----------------------------------------------------------------------- inputs

variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  description = "Issuer with no https:// prefix."
  type        = string
}

variable "route53_zone_arn" {
  description = <<-EOT
    Scopes external-dns to one zone. Passing null grants it every zone in the
    account, which is the difference between a DNS controller and an account-wide
    DNS rewrite capability.
  EOT
  type        = string
  default     = null
}

variable "alb_controller_policy_json" {
  description = <<-EOT
    Path to the AWS-published load balancer controller IAM policy.

    NOT written by hand: it is ~180 statements with specific conditions, revised
    per controller release, and a subtly wrong copy fails at ALB-creation time
    with an AccessDenied that names an action you did not know it needed. Fetch
    the pinned upstream copy first:

      ./script/fetch-policies.sh

    A missing file fails the plan immediately, which is the right failure.
  EOT
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# --------------------------------------------------------------- trust policies
#
# The two condition keys are both load-bearing:
#
#   :sub  pins the exact namespace AND ServiceAccount name. Without it any
#         ServiceAccount in the cluster could assume the role.
#   :aud  pins the audience to sts.amazonaws.com. Without it a token minted for
#         another audience is accepted.
#
# StringEquals, never StringLike — a wildcard here is a cluster-wide grant.

locals {
  # namespace/name pairs, matching what the Helm charts in ../../platform create.
  service_accounts = {
    alb_controller = { namespace = "kube-system", name = "aws-load-balancer-controller" }
    external_dns   = { namespace = "kube-system", name = "external-dns" }
    autoscaler     = { namespace = "kube-system", name = "cluster-autoscaler" }
  }
}

data "aws_iam_policy_document" "assume" {
  for_each = local.service_accounts

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ------------------------------------------------- aws load balancer controller

resource "aws_iam_role" "alb_controller" {
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.assume["alb_controller"].json
  tags               = var.tags
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-alb-controller"
  description = "AWS-published policy for the load balancer controller."
  policy      = file(var.alb_controller_policy_json)
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ---------------------------------------------------------------- external-dns

data "aws_iam_policy_document" "external_dns" {
  # Writing records. Scoped to the one zone when its ARN is known — the whole
  # point of passing it in.
  statement {
    sid       = "ChangeRecords"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = var.route53_zone_arn != null ? [var.route53_zone_arn] : ["arn:aws:route53:::hostedzone/*"]
  }

  # Discovery. ListHostedZones cannot be resource-scoped — there is no zone to
  # name before you have listed them — so this stays "*" by necessity. It is
  # read-only.
  statement {
    sid    = "DiscoverZones"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.assume["external_dns"].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "external-dns"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

# ------------------------------------------------------------ cluster autoscaler

data "aws_iam_policy_document" "autoscaler" {
  # Read side. Describe* cannot be resource-scoped on the autoscaling API.
  statement {
    sid    = "Describe"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeImages",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  # Write side — the two actions that actually move nodes, restricted to groups
  # tagged as belonging to THIS cluster. Untagged groups, and other clusters'
  # groups, are unreachable even though the actions are granted.
  statement {
    sid    = "Scale"
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role" "autoscaler" {
  name               = "${var.cluster_name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.assume["autoscaler"].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "autoscaler" {
  name   = "cluster-autoscaler"
  role   = aws_iam_role.autoscaler.id
  policy = data.aws_iam_policy_document.autoscaler.json
}

# ---------------------------------------------------------------------- outputs

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

output "autoscaler_role_arn" {
  value = aws_iam_role.autoscaler.arn
}

output "service_accounts" {
  description = "The namespace/name pairs the trust policies pin. The Helm values must match exactly."
  value       = local.service_accounts
}
