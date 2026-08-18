# Copy to terraform.tfvars and edit.

region = "us-east-1"

# WHICH CLUSTER THESE CONTROLLERS SIT ON.
#
#   "infra"          EKS. Token auth through the AWS API, IRSA roles available, so the
#                    AWS-integrated controllers install by default.
#   "infra-kubeadm"  Your own control plane on EC2. No AWS API knows it exists, so the
#                    providers use kubeconfig_path below — get kubectl working first.
#                    IRSA does not exist there, so the ALB controller, external-dns and
#                    the autoscaler default OFF and ingress-nginx defaults ON.
cluster_stack = "infra"

# Only used when cluster_stack = "infra-kubeadm".
# kubeconfig_path    = "~/.kube/config"
# kubeconfig_context = null

# Override any default: null means "decide from cluster_stack".
# enable_alb_controller     = null
# enable_external_dns       = null
# enable_cluster_autoscaler = null
# enable_ingress_nginx      = null
# enable_metrics_server     = true

# From `cd ../bootstrap && terraform output -raw state_bucket`. This stack reads
# infra/'s outputs out of the same bucket.
state_bucket = "k8s-tfstate-866409326838"

# NOT OPTIONAL IN PRACTICE. external-dns runs with policy=sync, which means it
# DELETES records it believes are orphaned. An empty filter makes every hosted
# zone in the account eligible, so a misread would remove records belonging to
# something else. Set it to the one zone this cluster owns.
# NOT OPTIONAL IN PRACTICE. external-dns runs policy=sync, which DELETES records it
# believes are orphaned — an empty filter makes every hosted zone in the account
# eligible. With no zone at all it simply matches nothing, which is safe.
domain_filter = "example.invalid"

# Keep in step with LBC_VERSION in script/fetch-policies.sh — chart 1.8.2
# ships controller v2.8.2. A controller newer than its IAM policy calls actions
# the policy does not grant, and fails at ALB-creation time.
alb_controller_chart_version = "1.8.2"
