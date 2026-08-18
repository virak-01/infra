# Remote state backend. Run this ONCE, before infra/, with local state.
#
# The chicken-and-egg: infra/backend.tf points at an S3 bucket that has to exist
# before `terraform init` can run. So this root module creates the bucket and the
# lock table using LOCAL state, and its own state file is committed nowhere and
# needed almost never — the two resources here are create-once and never change.
#
#   cd terraform/bootstrap
#   terraform init
#   terraform apply                      # no -var: the name derives from your account
#   terraform output -raw state_bucket
#
# RUN IT ONCE. If you apply again with a DIFFERENT name, Terraform plans to replace the
# bucket — an S3 bucket name is ForceNew — and prevent_destroy below stops it:
#
#   Error: Instance cannot be destroyed … has lifecycle.prevent_destroy set
#
# That is the guard working, not a problem to route around. You almost never want a new
# bucket; you want the name of the one you already have:
#
#   terraform output -raw state_bucket
#
# Passing -var also avoids the interactive prompt, where it is easy to type a name that
# differs from the one in state by an account digit.
#
# Deliberately NOT part of infra/: a stack cannot hold the bucket its own state
# lives in. Destroying infra would delete the record of what it destroyed.

variable "region" {
  description = "Region for the state bucket. Keep it the same as the platform region."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = <<-EOT
    OVERRIDE ONLY. Leave empty and the name is derived as

      k8s-tfstate-<account-id>-<region>

    which is globally unique (S3 names are global across every AWS account) and
    DETERMINISTIC — so `terraform apply` needs no -var and re-running produces the same
    name instead of planning to replace the bucket.

    Set it only to adopt a bucket created under a different name. Applying with a name
    that differs from the one in state is what produces:

      Error: Instance cannot be destroyed … has lifecycle.prevent_destroy set
  EOT
  type        = string
  default     = ""
}

data "aws_caller_identity" "current" {}

locals {
  # Derived rather than required. The account id is the only part that has to be
  # unique, and it is knowable — asking a human to type it is how the two diverge.
  bucket_name = var.state_bucket_name != "" ? var.state_bucket_name : "k8s-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
}

variable "lock_table_name" {
  description = "DynamoDB table for state locking. Only used when create_lock_table is true."
  type        = string
  default     = "terraform-locks"
}

variable "create_lock_table" {
  description = <<-EOT
    Create the DynamoDB lock table.

    NO LONGER NEEDED. The backends now use `use_lockfile = true`, which locks with an
    object in the state bucket itself — Terraform deprecated `dynamodb_table` in 1.11.

    Defaults to true so an account that already has the table sees no change: flipping
    it to false would plan a destroy, and prevent_destroy below would block it. Set
    false on a NEW account to skip the table entirely.
  EOT
  type        = bool
  default     = true
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

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

# Versioning keeps every historical state file forever unless told otherwise. Ninety
# days is far longer than any recovery window and stops the bucket growing without
# bound — a busy stack writes a new version on every apply.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
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
  count = var.create_lock_table ? 1 : 0

  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # A lock table is cheap to lose — the locks are transient — but PITR costs almost
  # nothing at this size and removes any question during an incident.
  point_in_time_recovery {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "state_bucket" {
  description = <<-EOT
    The bucket name. NOT pasted into any backend.tf — those carry no literal bucket.
    Pass it at init instead:

      terraform -chdir=terraform/infra init -backend-config="bucket=$(terraform -chdir=terraform/bootstrap output -raw state_bucket)"

    This is also how you recover the name if you have forgotten it. Re-applying with a
    different one tries to replace the bucket and is blocked by prevent_destroy.
  EOT
  value = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "Null when create_lock_table is false — the backends use S3 native locking now."
  value       = var.create_lock_table ? aws_dynamodb_table.locks[0].name : null
}

output "next_step" {
  description = "What to run after this stack."
  value       = <<-EOT

    State bucket ready: ${aws_s3_bucket.state.id}

    Write it into every backend, then use the stacks:

      ./script/tf-backend.sh --write
      cd terraform/infra && terraform init && terraform apply

    A backend block takes no variables, so the bucket has to be a literal in
    backend.tf — that script puts it there and checks the bucket is reachable first.
  EOT
}
