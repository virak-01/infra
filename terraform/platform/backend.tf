# Remote state for the platform stack.
#
# The bucket and region are LITERAL here so that `terraform init` needs no flags. Both
# are overridden at init time when they differ:
#
#   terraform init \
#     -backend-config="bucket=<other-bucket>" \
#     -backend-config="region=<other-region>"
#
# ONE-TIME EDIT ON A NEW ACCOUNT. ../bootstrap names the bucket
# k8s-tfstate-<account-id>-<region>, so fill in your account once:
#
#   ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
#   sed -i "s/<ACCOUNT_ID>/$ACCOUNT/" terraform/*/backend.tf
#
# A backend block accepts no variables and no interpolation — Terraform reads it before
# evaluating anything else — so a literal plus an override flag is the only mechanism
# available. Keep `region` equal to the provider's, or state is read from one account
# while resources are created in another.
#
# STATE ISOLATION IS THE `key` LINE. Every root module writes a different object in the
# shared bucket; state is the record of what a module owns, and two modules cannot own
# one record. Sharing a key would make each apply destroy the other stack.

terraform {
  backend "s3" {
    bucket = "k8s-tfstate-<ACCOUNT_ID>-us-east-1"
    key    = "platform/terraform.tfstate"
    region = "us-east-1"

    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
