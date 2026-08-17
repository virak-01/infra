# Remote state. Fill in the bucket from `cd ../bootstrap && terraform output -raw state_bucket`.
#
# A backend block takes no variables and no interpolation — Terraform reads it
# before evaluating anything else — so the bucket name is literal here. Either
# edit it, or delete the `bucket` line and pass it at init time:
#
#   terraform init -backend-config="bucket=<name>"
#
# LOCAL STATE IS NOT AN OPTION once more than one person, or one CI job, can
# apply. Two concurrent applies against a local state file cannot lock, and the
# result is a state that describes neither the old nor the new infrastructure.

terraform {
  backend "s3" {
    bucket = "REPLACE-ME-terraform-state-<account-id>"
    key    = "infra/terraform.tfstate"
    region = "us-east-1"

    # Drop this line and use `use_lockfile = true` instead on Terraform 1.10+,
    # which locks via S3 and needs no table.
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
