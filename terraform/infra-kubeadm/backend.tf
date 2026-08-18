# Remote state for the infra-kubeadm stack.
#
# The bucket and region are LITERAL here so that `terraform init` needs no flags. Both
# are overridden at init time when they differ:
#
#   terraform init \
#     -backend-config="bucket=<other-bucket>" \
#     -backend-config="region=<other-region>"
#
# THE BUCKET MUST ALREADY EXIST — the backend never creates it. If init fails with
# "S3 bucket ... does not exist", the name here disagrees with what ../bootstrap
# actually made. Read the real one back with:
#
#   aws s3 ls | grep tfstate
#
# ON A DIFFERENT ACCOUNT, point this at that account's bucket:
#
#   ./script/tf-backend.sh --write        # discovers it and writes it here
#
# or by hand, from the repo root:
#
#   sed -i -E 's|(bucket[[:space:]]*=[[:space:]]*")[^"]*(")|\1<name>\2|' terraform/*/backend.tf
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
    bucket = "k8s-tfstate-866409326838"
    key    = "infra-kubeadm/terraform.tfstate"
    region = "us-east-1"

    # S3 native locking. Replaces the DynamoDB table, which Terraform deprecated in
    # 1.11 — the lock is now an object in this same bucket, so there is one less
    # resource to create and nothing extra to pay for.
    use_lockfile = true
    encrypt      = true
  }
}
