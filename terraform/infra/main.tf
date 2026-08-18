# THE AWS STACK. One VPC, one cluster, one set of registries, one certificate.
#
# WHY THERE IS NO envs/uat AND envs/prod HERE.
#
# UAT and prod share a single cluster and are separated by NAMESPACE — that is
# the design of the manifests repo, where `ENV` names both the overlay directory
# and the namespace. So there is no per-environment AWS infrastructure to
# separate: both environments pull from the same ECR repositories with different
# tags, sit behind the same ALB, and share one wildcard certificate.
#
# Splitting this into two root modules would create two VPCs and two clusters,
# which is a different (more expensive, more correct-in-the-abstract) platform
# than the one the manifests describe. If you ever want that, this whole stack
# becomes a module and envs/ call it twice.
#
# Environment separation is enforced in Kubernetes, not here: namespaces,
# NetworkPolicies, and separate Argo CD Applications.

# ─── inputs ────────────────────────────────────────────────────────────────────
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "bubernestes"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "az_count" {
  type    = number
  default = 3
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "domain_name" {
  description = "Set to null to skip DNS and TLS entirely and reach the ALB by its own hostname."
  type        = string
  default     = null
}

variable "create_zone" {
  type    = bool
  default = false
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium", "t3a.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 6
}

variable "public_access_cidrs" {
  description = "Narrow this. 0.0.0.0/0 leaves the Kubernetes API endpoint reachable from the internet."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "alb_controller_policy_json" {
  description = "Override the load balancer controller IAM policy path. Null uses the module's own copy, fetched by ./script/fetch-policies.sh."
  type        = string
  default     = null
}

# ─── modules ───────────────────────────────────────────────────────────────────
module "network" {
  source = "../modules/network"

  name               = var.cluster_name
  cluster_name       = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
}

module "registry" {
  source = "../modules/registry"

  # Matches the `newName:` suffixes in both overlays. `website` serves /,
  # `core` serves /api, `auth` serves /api/auth and /api/health.
  repositories = ["website", "core", "auth"]
}

# Skipped entirely when domain_name is null — the ALB is then reachable by its own
# hostname over HTTP, and the certificate-arn / ssl-redirect annotations must come
# out of k8s/components/ingress-alb or every request is redirected to a
# certificate that does not exist.
module "dns" {
  source = "../modules/dns"
  count  = var.domain_name != null ? 1 : 0

  domain_name = var.domain_name
  create_zone = var.create_zone
}

module "cluster" {
  source = "../modules/cluster"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version

  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.network.alb_security_group_id

  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_min_size

  public_access_cidrs = var.public_access_cidrs
}

module "iam_irsa" {
  source = "../modules/iam-irsa"

  cluster_name      = var.cluster_name
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_provider_url = module.cluster.oidc_provider_url

  # null when DNS is skipped, which widens the external-dns policy to every zone.
  # Harmless with no zones; tighten it as soon as one exists.
  route53_zone_arn = var.domain_name != null ? module.dns[0].zone_arn : null

  alb_controller_policy_json = var.alb_controller_policy_json
}

# ─── outputs ───────────────────────────────────────────────────────────────────
#
# Everything below is a value the MANIFESTS repo hardcodes today. Kustomize cannot
# read Terraform state, so these have to be carried across — see the
# `kustomize_values` output for all of them at once, and the README for the two
# honest ways to move them.

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "cluster_version" {
  description = "The Cluster Autoscaler image minor version must match this."
  value       = module.cluster.cluster_version
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.cluster.cluster_name}"
}

output "registry_host" {
  description = "Replaces the <acct>.dkr.ecr.<region>.amazonaws.com prefix in both overlays."
  value       = module.registry.registry_host
}

output "repository_urls" {
  value = module.registry.repository_urls
}

output "certificate_arn" {
  description = "alb.ingress.kubernetes.io/certificate-arn in k8s/components/ingress-alb."
  value       = var.domain_name != null ? module.dns[0].certificate_arn : null
}

output "vpc_cidr" {
  description = "The NetworkPolicy ipBlock in k8s/components/ingress-alb."
  value       = module.network.vpc_cidr
}

output "alb_security_group_id" {
  description = "alb.ingress.kubernetes.io/security-groups on the Ingress. Required to close the node-SG seam."
  value       = module.network.alb_security_group_id
}

output "node_group_asg_names" {
  value = module.cluster.node_group_asg_names
}

output "zone_name_servers" {
  description = "Point the registrar here when create_zone was true. Nothing resolves and ACM never validates until you do."
  value       = var.domain_name != null ? module.dns[0].name_servers : []
}

# Consumed by ../platform via remote state, and by the sync script.
output "irsa_role_arns" {
  value = {
    alb_controller = module.iam_irsa.alb_controller_role_arn
    external_dns   = module.iam_irsa.external_dns_role_arn
    autoscaler     = module.iam_irsa.autoscaler_role_arn
  }
}

output "kustomize_values" {
  description = "Every value the manifests repo needs, in one place. `terraform output -json kustomize_values`."
  value = {
    registry_host         = module.registry.registry_host
    certificate_arn       = var.domain_name != null ? module.dns[0].certificate_arn : null
    vpc_cidr              = module.network.vpc_cidr
    alb_security_group_id = module.network.alb_security_group_id
    region                = var.region
    cluster_name          = module.cluster.cluster_name
  }
}
