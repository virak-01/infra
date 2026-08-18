# The state bucket that ALREADY EXISTS in this account.
#
# Set explicitly rather than left to derive. bootstrap would otherwise compute
# k8s-tfstate-<account>-<region>, and this bucket was created earlier under a name
# without the region suffix — a different name means Terraform plans to REPLACE the
# bucket (an S3 name is ForceNew), and prevent_destroy stops it:
#
#   Error: Instance cannot be destroyed … has lifecycle.prevent_destroy set
#
# Pinning it here makes `terraform apply` in this directory a no-op forever, which is
# what a create-once stack should be.
#
# On a NEW account, delete this file and let the name derive.
state_bucket_name = "k8s-tfstate-866409326838"
