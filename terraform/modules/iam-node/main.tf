# Instance roles for the control plane and the workers.
#
# THIS MODULE IS HOW THE JOIN TOKEN STAYS OUT OF GIT.
#
# A kubeadm join command contains a bootstrap token and the CA certificate hash.
# Together they are enough to enrol a node in the cluster, so the command is a
# credential and must not be committed, passed as a Terraform variable (it would
# land in state in cleartext), or baked into user-data (readable by anything on the
# instance via IMDS).
#
# Instead:
#   1. the control plane MINTS a short-lived token during bootstrap and writes the
#      join command to SSM Parameter Store as a SecureString;
#   2. workers READ it using this role and nothing else;
#   3. the token expires — see --ttl in kubernetes/bootstrap/control-plane.sh — so a
#      leaked parameter stops being useful.
#
# The two roles are deliberately asymmetric. The control plane can write the
# parameter and cannot read it back; workers can read and cannot write. Neither can
# touch any other parameter, because both policies name this one path.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Constructed rather than referenced — see the variable's description.
  join_parameter_arn = format(
    "arn:aws:ssm:%s:%s:parameter%s",
    data.aws_region.current.name,
    data.aws_caller_identity.current.account_id,
    var.join_command_parameter_name,
  )
}

# EC2 instances assume their instance-profile role through this service principal.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ============================================================ control plane

resource "aws_iam_role" "control_plane" {
  name_prefix        = "${var.name_prefix}-cp-"
  description        = "Kubernetes control-plane node. Writes the join command to SSM."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = merge(var.tags, { Role = "control-plane" })
}

data "aws_iam_policy_document" "control_plane" {
  # WRITE ONLY, and to exactly one parameter path. No ssm:GetParameter: the control
  # plane produces the join command and never needs to read it back, so omitting
  # the read means a compromised control-plane pod cannot recover a token minted
  # earlier.
  statement {
    sid    = "PublishJoinCommand"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:AddTagsToResource",
    ]
    resources = [local.join_parameter_arn]
  }

  # A SecureString is encrypted with the AWS-managed key alias/aws/ssm, and the
  # caller needs kms:Encrypt for it. The ViaService condition means this grant only
  # works when the call arrives THROUGH SSM — the role cannot use the key to
  # encrypt anything else.
  statement {
    sid       = "EncryptViaSSM"
    effect    = "Allow"
    actions   = ["kms:Encrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "control_plane" {
  name_prefix = "join-command-write-"
  role        = aws_iam_role.control_plane.id
  policy      = data.aws_iam_policy_document.control_plane.json
}

resource "aws_iam_role_policy_attachment" "control_plane_ssm" {
  count = var.enable_ssm_session_manager ? 1 : 0

  role       = aws_iam_role.control_plane.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "control_plane" {
  name_prefix = "${var.name_prefix}-cp-"
  role        = aws_iam_role.control_plane.name
  tags        = var.tags
}

# =================================================================== workers

resource "aws_iam_role" "worker" {
  name_prefix        = "${var.name_prefix}-worker-"
  description        = "Kubernetes worker node. Reads the join command from SSM."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = merge(var.tags, { Role = "worker" })
}

data "aws_iam_policy_document" "worker" {
  # READ ONLY, one path. GetParameters as well as GetParameter because the AWS CLI
  # uses the plural form for some invocations and a policy granting only the
  # singular fails with an AccessDenied naming an action you did not write.
  statement {
    sid    = "ReadJoinCommand"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [local.join_parameter_arn]
  }

  # Decrypting the SecureString, and only when the call comes through SSM.
  statement {
    sid       = "DecryptViaSSM"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "worker" {
  name_prefix = "join-command-read-"
  role        = aws_iam_role.worker.id
  policy      = data.aws_iam_policy_document.worker.json
}

resource "aws_iam_role_policy_attachment" "worker_ssm" {
  count = var.enable_ssm_session_manager ? 1 : 0

  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "worker" {
  name_prefix = "${var.name_prefix}-worker-"
  role        = aws_iam_role.worker.name
  tags        = var.tags
}
