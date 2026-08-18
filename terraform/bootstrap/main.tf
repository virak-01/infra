# Remote state backend. Run this ONCE, before infra/, with local state.
#
# The chicken-and-egg: infra/backend.tf points at an S3 bucket that has to exist
# before `terraform init` can run. So this root module creates the bucket and the
# lock table using LOCAL state, and its own state file is committed nowhere and
# needed almost never — the two resources here are create-once and never change.
#
#   cd bootstrap
#   terraform init && terraform apply
#   terraform output -raw state_bucket     # paste into ../infra/backend.tf
#
# Deliberately NOT part of infra/: a stack cannot hold the bucket its own state
# lives in. Destroying infra would delete the record of what it destroyed.

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
      Stack     = "bootstrap"
      Repo      = "aws-kubernetes"
    }
  }
}

variable "region" {
  description = "Region for the state bucket. Keep it the same as the platform region."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = <<-EOT
    Globally unique S3 bucket name for Terraform state. S3 bucket names are global
    across all AWS accounts, so this must be unique to you — the account id suffix
    below is the usual way.
  EOT
  type        = string
}

variable "lock_table_name" {
  description = "DynamoDB table for state locking."
  type        = string
  default     = "terraform-locks"
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # State files describe live infrastructure. Losing one means losing the ability
  # to change or destroy what it tracks, so this bucket is not disposable.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning is the actual recovery mechanism for a corrupted or truncated state
# push. Without it a bad apply is unrecoverable.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State contains resource attributes in cleartext — subnet ids, ARNs, and any
# sensitive output. It is never public.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Two concurrent applies against one state file interleave writes and corrupt it.
#
# Terraform 1.10+ can do this with an S3 lock file instead (`use_lockfile = true`
# in the backend block, no table at all). DynamoDB is kept here because it works
# on every version and costs nothing at this scale — drop this resource and the
# `dynamodb_table` line in ../infra/backend.tf if you would rather not have it.
resource "aws_dynamodb_table" "locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "state_bucket" {
  description = "Put this in ../infra/backend.tf and ../platform/backend.tf."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.locks.name
}

output "env_lines" {
  description = "Two lines for .env. After that, `terraform init` needs no flags."
  value       = <<-EOT

    Add to .env:

      TF_STATE_BUCKET=${aws_s3_bucket.state.id}
      TF_CLI_ARGS_init=-backend-config=bucket=${aws_s3_bucket.state.id}

    Then:

      ./script/with-aws-env.sh terraform -chdir=terraform/infra init

    NOTHING TO PASTE INTO backend.tf. The backend blocks under terraform/ already carry
    everything that can be literal — the state key, the lock table, encryption. They
    deliberately omit two values:

      region   read from AWS_REGION / AWS_DEFAULT_REGION, so the backend and the
               provider cannot disagree about which account they are working in.
      bucket   has no environment fallback in the S3 backend, which is what
               TF_CLI_ARGS_init above is for.

    The explicit form, if you prefer nothing implicit:

      terraform -chdir=terraform/infra init -backend-config="bucket=${aws_s3_bucket.state.id}"
  EOT
}
