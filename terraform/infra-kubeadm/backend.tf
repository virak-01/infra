# Remote state for KUBEADM — the kubeadm stack.
#
# A BACKEND BLOCK TAKES NO VARIABLES. Terraform reads this before it evaluates
# variables, locals or providers, so `region = var.region` fails outright with
# "Variables may not be used here". Everything below is therefore either a literal or
# supplied from outside at init time.
#
# WHICH IS WHY region IS ABSENT. The S3 backend resolves it from the standard AWS
# environment — AWS_REGION or AWS_DEFAULT_REGION — exactly like the provider does. Your
# .env sets both, so loading it is enough:
#
#   ./script/with-aws-env.sh terraform -chdir=terraform/infra-kubeadm init
#
# Hard-coding it here would mean the backend and the provider could disagree about the
# region, and state would be read from one account's bucket while resources were
# created in another.
#
# THE BUCKET HAS NO SUCH FALLBACK — there is no environment variable the S3 backend
# reads for it. Supply it one of two ways, both driven by .env:
#
#   TF_CLI_ARGS_init in .env      terraform appends it to every `init`, so plain
#                                 `terraform init` just works. This is the shipped path.
#
#   explicitly on the command line, if you prefer nothing implicit:
#     terraform -chdir=terraform/infra-kubeadm init -backend-config="bucket=$TF_STATE_BUCKET"
#
# Get the value once from:
#   terraform -chdir=terraform/bootstrap output -raw state_bucket
#
# STATE ISOLATION IS THE `key` LINE, and it is literal on purpose. Each root module
# owns a different object in the shared bucket; state is the record of what a module
# owns, and two modules cannot own one record. Sharing a key would make each apply
# destroy the other stack's infrastructure.

terraform {
  backend "s3" {
    key = "infra-kubeadm/terraform.tfstate"

    # Constants, the same for every stack.
    dynamodb_table = "terraform-locks"
    encrypt        = true

    # bucket — from TF_CLI_ARGS_init or -backend-config. See above.
    # region — from AWS_REGION / AWS_DEFAULT_REGION. See above.
  }
}
