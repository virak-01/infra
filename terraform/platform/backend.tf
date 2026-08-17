# Same bucket as infra/, different key. Two stacks, two state files, one bucket.
#
# Sharing a key would mean each apply destroying the other's resources — state is
# the record of what a root module owns, and two modules cannot own one record.

terraform {
  backend "s3" {
    bucket = "REPLACE-ME-terraform-state-<account-id>"
    key    = "platform/terraform.tfstate"
    region = "us-east-1"

    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
