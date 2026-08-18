# THE OPS BOX — an EC2 instance you run terraform and kubectl from.
#
# WHY THIS EXISTS. Running the stacks from a laptop means long-lived access keys in a
# .env file: a credential that never expires until someone revokes it, sitting on a
# machine that travels. An instance profile has none of those properties — the SDK
# fetches short-lived credentials from IMDS, they rotate automatically, and there is
# nothing on disk to leak. So: no .env, no ~/.aws/credentials, no keys anywhere.
#
# RUN THIS ONE STACK FIRST, AND FROM SOMEWHERE ELSE. It cannot be created by the
# Terraform it is meant to run. Two ways, neither needing anything installed locally:
#
#   AWS CloudShell   a browser shell with your console credentials already loaded.
#                    Clone the repo there, apply this directory, then never use it again.
#   the console      create an instance by hand and attach the role this stack defines.
#
# LOCAL STATE, deliberately — like ../bootstrap. This box must outlive
# `terraform destroy` of the other stacks, and storing its state in a bucket the other
# stacks manage would couple its life to theirs.
#
# NO INBOUND PORTS AT ALL. No SSH, no key pair, no public ingress. Access is Session
# Manager, which reaches the instance through an outbound connection the SSM agent
# makes — so there is no port to scan and no key to lose:
#
#   aws ssm start-session --target <instance-id>

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "ops-box"
      Repo      = "aws-kubernetes"
    }
  }
}

# ----------------------------------------------------------------------- inputs

variable "region" {
  description = "Region for the ops box. Keep it the same as the platform region."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for every resource here."
  type        = string
  default     = "k8s-ops"
}

variable "instance_type" {
  description = <<-EOT
    Instance type. This box only runs terraform, kubectl and git — it is not doing
    real work, and t3.small is comfortable. terraform plan on these stacks peaks
    around 500 MB.
  EOT
  type        = string
  default     = "t3.small"
}

variable "vpc_id" {
  description = <<-EOT
    VPC for the ops box. Null uses the account's default VPC.

    NOT the VPC the platform stacks create — that one does not exist yet when this
    runs, and putting the ops box inside it would mean `terraform destroy` of the
    infrastructure taking out the machine running the destroy.
  EOT
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet for the ops box. Null picks the first available in the VPC. Must have a route to the internet — the SSM agent connects outbound."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "GiB. Terraform provider plugins are large; 20 leaves room for several stacks' .terraform directories."
  type        = number
  default     = 20
}

variable "terraform_version" {
  description = "Terraform version installed by user-data. Pinned so every operator on this box runs the same one."
  type        = string
  default     = "1.9.8"
}

variable "kubectl_version" {
  description = "kubectl version. Should be within one minor of the cluster."
  type        = string
  default     = "1.31.0"
}

# --------------------------------------------------------------------- discovery

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_vpc" "selected" {
  id      = var.vpc_id
  default = var.vpc_id == null ? true : null
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

locals {
  subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.selected.ids[0]
}

# ============================================================================ iam
#
# WHAT A TERRAFORM RUNNER ACTUALLY NEEDS, and an honest note about it.
#
# These stacks create IAM roles, an OIDC provider and instance profiles. Anything that
# can create an IAM role can create one with AdministratorAccess and assume it — so a
# Terraform runner with iam:CreateRole is, in practice, an administrator. Scoping the
# other services below is still worth doing (it limits blast radius from a mistake, and
# it documents what the stacks touch), but do not mistake it for containment.
#
# THE REAL CONTROL IS WHO CAN REACH THIS BOX. No inbound ports, no key pair, and
# Session Manager access governed by IAM on your own principal — that is the boundary,
# and it is a much better one than a static key on a laptop.

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ops" {
  name_prefix        = "${var.name}-"
  description        = "Runs terraform for the aws-kubernetes stacks."
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "terraform" {
  # The services the stacks actually create. Not resource-scoped: Terraform creates
  # resources that do not exist yet, so there is no ARN to name in advance.
  statement {
    sid    = "PlatformServices"
    effect = "Allow"
    actions = [
      "ec2:*",                  # vpc, subnets, igw, nat, routes, security groups, instances
      "eks:*",                  # the cluster and its node groups and addons
      "ecr:*",                  # the three repositories
      "acm:*",                  # the certificate
      "route53:*",              # the hosted zone and validation records
      "elasticloadbalancing:*", # read-only in practice — the controller owns the ALB
      "autoscaling:*",          # node group ASGs and the autoscaler's tags
      "logs:*",                 # the EKS control-plane log group
      "ssm:*",                  # the kubeadm join parameter, and Session Manager
      "kms:*",                  # SecureString encryption via SSM
    ]
    resources = ["*"]
  }

  # IAM, separated so it is visible rather than buried in the list above. See the note
  # at the top of this section: this is what makes the role admin-equivalent.
  statement {
    sid    = "IAMForClusterRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:CreateServiceLinkedRole",
      # PassRole is how Terraform hands a role to EKS and to EC2. Without it, creating
      # a cluster fails with an error about the service role rather than about IAM.
      "iam:PassRole",
    ]
    resources = ["*"]
  }

  # Remote state. Scoped, because these DO exist by the time Terraform runs.
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
    ]
    resources = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*", "arn:aws:s3:::*terraform-state*", "arn:aws:s3:::*terraform-state*/*"]
  }

  statement {
    sid       = "TerraformLock"
    effect    = "Allow"
    actions   = ["dynamodb:CreateTable", "dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/terraform-locks"]
  }

  # Reading its own identity, which `aws sts get-caller-identity` and several data
  # sources need.
  statement {
    sid       = "ReadOwnIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "terraform" {
  name_prefix = "terraform-"
  role        = aws_iam_role.ops.id
  policy      = data.aws_iam_policy_document.terraform.json
}

# Session Manager. This is what replaces SSH — the agent dials out, so no inbound rule
# and no key pair are needed.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ops.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ops" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.ops.name
}

# ================================================================ security group

resource "aws_security_group" "ops" {
  name_prefix = "${var.name}-"
  description = "Ops box. Outbound only — Session Manager needs no inbound rule."
  vpc_id      = data.aws_vpc.selected.id

  tags = { Name = var.name }

  lifecycle {
    create_before_destroy = true
  }
}

# NO INGRESS RULES AT ALL, and that is the point. The SSM agent establishes an outbound
# connection to the Session Manager service and your session is tunnelled back through
# it, so there is nothing listening to reach. Adding an SSH rule here would undo the
# main security benefit of this design.

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.ops.id
  description       = "Outbound: SSM, package repos, the AWS APIs, the cluster endpoint"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ==================================================================== the instance

resource "aws_instance" "ops" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.ops.id]
  iam_instance_profile   = aws_iam_instance_profile.ops.name

  # A public IP so the SSM agent can reach the service without a NAT gateway. Nothing
  # can connect IN — the security group has no ingress rules.
  associate_public_ip_address = true

  # NO key_name. There is no SSH daemon exposure to key, and a key pair would put a
  # private key somewhere.

  user_data                   = local.user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
    tags        = { Name = "${var.name}-root" }
  }

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 required. IMDSv1 answers an unauthenticated GET, and this instance's role
    # is the most powerful credential in the account.
    http_tokens = "required"
    # 1, not 2: nothing containerised runs here, so no process needs an extra hop —
    # and a lower limit narrows what could read the role.
    http_put_response_hop_limit = 1
  }

  tags = { Name = var.name }
}

# An Elastic IP so the address survives a stop/start. That matters because it is the
# address you allowlist in `public_access_cidrs` for the EKS API endpoint — without a
# stable IP, every restart locks the box out of the cluster it manages.
resource "aws_eip" "ops" {
  instance = aws_instance.ops.id
  domain   = "vpc"
  tags     = { Name = var.name }
}

locals {
  user_data = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    exec > >(tee -a /var/log/ops-box-setup.log) 2>&1

    echo "[$(date -u +%FT%TZ)] provisioning ops box"

    dnf install -y git unzip jq

    # Terraform, pinned. Every operator on this box then runs the same version, which
    # matters because a newer Terraform writes a state file older versions refuse.
    curl -fsSL "https://releases.hashicorp.com/terraform/${var.terraform_version}/terraform_${var.terraform_version}_linux_amd64.zip" -o /tmp/tf.zip
    unzip -o -q /tmp/tf.zip -d /usr/local/bin
    chmod +x /usr/local/bin/terraform
    rm -f /tmp/tf.zip

    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${var.kubectl_version}/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl

    # The AWS CLI ships on Amazon Linux 2023, and the SSM agent is preinstalled and
    # enabled — that is why this AMI was chosen over Ubuntu here.

    cat >/etc/profile.d/ops-box.sh <<'PROFILE'
    export AWS_REGION=${data.aws_region.current.name}
    export AWS_DEFAULT_REGION=${data.aws_region.current.name}
    PROFILE

    cat >/etc/motd <<'MOTD'

      aws-kubernetes ops box
      ----------------------
      Credentials come from the instance profile. There is no .env here and no
      ~/.aws/credentials — do not create either.

        aws sts get-caller-identity        confirm which role you are
        git clone <your-repo-url>
        cd aws-kubernetes

        cd terraform/bootstrap && terraform init && terraform apply
        cd ../infra            && terraform init && terraform apply

      Full runbook: docs/new-aws-account.md

    MOTD

    echo "[$(date -u +%FT%TZ)] ready: terraform ${var.terraform_version}, kubectl ${var.kubectl_version}"
  EOT
}

# ---------------------------------------------------------------------- outputs

output "instance_id" {
  description = "Connect with: aws ssm start-session --target <this>"
  value       = aws_instance.ops.id
}

output "connect_command" {
  value = "aws ssm start-session --target ${aws_instance.ops.id} --region ${data.aws_region.current.name}"
}

output "public_ip" {
  description = <<-EOT
    Stable Elastic IP. PUT THIS IN public_access_cidrs — as a /32 — in
    ../infra/terraform.tfvars, or the ops box cannot reach the EKS API endpoint it
    just created.
  EOT
  value = aws_eip.ops.public_ip
}

output "public_access_cidr_line" {
  description = "Copy straight into ../infra/terraform.tfvars."
  value       = "public_access_cidrs = [\"${aws_eip.ops.public_ip}/32\"]"
}

output "role_arn" {
  description = "The role Terraform runs as on the box. No static keys exist for it."
  value       = aws_iam_role.ops.arn
}
