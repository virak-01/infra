# THE CONTROLLERS the manifests depend on. A SEPARATE ROOT MODULE from infra/,
# and that separation is not organisational tidiness.
#
# The helm and kubernetes providers need cluster credentials to build their plan.
# In a single root module those credentials are attributes of a cluster that does
# not exist during the first plan, so the provider is configured from unknown
# values and Terraform fails before it applies anything — the well-known
# "Provider configuration is invalid" / "cannot connect to localhost:80" pair.
# Splitting the apply removes the problem instead of working around it with
# -target, which leaves state partially applied.
#
# Read in this order:
#   1. cd ../infra    && terraform apply
#   2. cd ../platform && terraform apply
#
# WHAT THIS INSTALLS, and why each is required rather than nice to have:
#   aws-load-balancer-controller  builds the ALB from the Ingress. Without it the
#                                 Ingress is inert: no address, no routing, no error.
#   external-dns                  writes DNS records from Ingress hosts, which is
#                                 what removes the manual Route 53 ALIAS step.
#   metrics-server                the HPAs report <unknown>/70% without it and
#                                 never scale.
#   cluster-autoscaler            adds nodes when pods go Pending.
#
# The APPLICATION manifests are NOT here. They live in k8s/ at the repo root, applied
# by Argo CD or `make deploy`. Terraform owns the platform; kustomize owns the
# workloads. Same repo, deliberately separate lifecycles.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "Same bucket as infra/, so this stack can read its outputs."
  type        = string
}

variable "domain_filter" {
  description = <<-EOT
    external-dns only touches zones matching this. An empty filter lets it manage
    every zone in the account, and it DELETES records it believes are orphaned —
    so an unfiltered external-dns with policy=sync can remove records belonging to
    something else entirely.
  EOT
  type        = string
  default     = ""
}

variable "alb_controller_chart_version" {
  description = "Keep the controller image in step with the IAM policy fetched by script/fetch-policies.sh (LBC_VERSION)."
  type        = string
  default     = "1.8.2"
}

provider "aws" {
  region = var.region
}

# ------------------------------------------------------------- infra's outputs

data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "infra/terraform.tfstate"
    region = var.region
  }
}

locals {
  cluster_name = data.terraform_remote_state.infra.outputs.cluster_name
  irsa         = data.terraform_remote_state.infra.outputs.irsa_role_arns
}

# Read live rather than from state: the cluster's CA data and endpoint are
# attributes that can change (an endpoint update, a CA rotation) without this
# state file being refreshed.
data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = local.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

# --------------------------------------------------- aws load balancer controller

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version
  namespace  = "kube-system"

  # serviceAccount.create is TRUE and the name is fixed: the IRSA trust policy in
  # modules/iam-irsa pins system:serviceaccount:kube-system:aws-load-balancer-controller
  # with StringEquals. Rename either side and the role becomes unassumable — the
  # controller then falls back to the node role and fails with AccessDenied.
  set {
    name  = "clusterName"
    value = local.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.irsa.alb_controller
  }

  # Stated explicitly. The controller can infer both on EKS, but an inferred
  # region has produced load balancers in the wrong one when the node metadata
  # answered slowly.
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  }

  # Two replicas: this controller is in the path of every Ingress change, and a
  # single replica makes a node drain a routing outage.
  set {
    name  = "replicaCount"
    value = "2"
  }
}

# ---------------------------------------------------------------- external-dns

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = "1.15.0"
  namespace  = "kube-system"

  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.irsa.external_dns
  }

  set {
    name  = "provider"
    value = "aws"
  }

  # THE GUARD RAIL. See the variable's description — with policy=sync below,
  # external-dns deletes records it considers orphaned, and an empty filter makes
  # every zone in the account fair game.
  set {
    name  = "domainFilters[0]"
    value = var.domain_filter
  }

  # `sync`, not `upsert-only`: sync removes the record when the Ingress host
  # changes or the Ingress is deleted. That is what keeps DNS honest, and it is
  # also what makes the domain filter mandatory rather than advisory.
  set {
    name  = "policy"
    value = "sync"
  }

  # Only Ingress objects. Without this it also claims Services of type
  # LoadBalancer, and would start writing records for anything anyone creates.
  set {
    name  = "sources[0]"
    value = "ingress"
  }

  # A TXT registry record marks which records this instance owns, so it never
  # deletes one it did not create. The owner id must be unique per cluster.
  set {
    name  = "txtOwnerId"
    value = local.cluster_name
  }

  depends_on = [helm_release.alb_controller]
}

# --------------------------------------------------------------- metrics-server

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = "3.12.2"
  namespace  = "kube-system"

  # Not optional for this platform: every Deployment in the manifests repo has an
  # HPA, and without metrics-server they all report <unknown>/70% and never scale.
  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }
}

# ------------------------------------------------------------ cluster autoscaler
#
# Installed by HELM here rather than by the manifests repo's
# k8s/cluster/aws/cluster-autoscaler, which cannot work on EKS: that Deployment
# pins itself to a control-plane node with a nodeSelector, and EKS control-plane
# nodes are not in your cluster — the pod stays Pending forever with no event
# naming the cause. Delete that directory from the manifests repo, or leave it for
# a future kubeadm cluster and never run `make cluster` against this one.

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.43.2"
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = local.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.region
  }

  set {
    name  = "rbac.serviceAccount.create"
    value = "true"
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.irsa.autoscaler
  }

  # AUTO-DISCOVERY, not --nodes=2:6:<name>. A managed node group's ASG name is
  # generated with a random suffix, so it cannot be written into a manifest ahead
  # of time. The autoscaler finds the group by the
  # k8s.io/cluster-autoscaler/<cluster> tag that modules/cluster applies instead,
  # and reads the bounds from the group itself — which also means the bounds can
  # never disagree with reality.
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  # Ten minutes of stable low utilisation before removing a node. Matches the
  # 600s scaleDown stabilization on the HPAs, so the two layers do not fight:
  # without this the autoscaler can remove a node while the HPA is still scaling
  # pods onto it.
  set {
    name  = "extraArgs.scale-down-unneeded-time"
    value = "10m"
  }

  depends_on = [helm_release.metrics_server]
}

# ---------------------------------------------------------------------- outputs

output "installed" {
  value = {
    alb_controller     = helm_release.alb_controller.version
    external_dns       = helm_release.external_dns.version
    metrics_server     = helm_release.metrics_server.version
    cluster_autoscaler = helm_release.cluster_autoscaler.version
  }
}

output "next_steps" {
  value = <<-EOT
    Controllers are installed. The manifests in this repo can now deploy:

      cd ../..                       # repo root
      make deploy rollout ENV=uat

    Before the first deploy, carry the terraform values into the overlays:

      ./script/sync-manifests.sh --check
      ./script/sync-manifests.sh --write

    See docs/terraform.md, section 5.
  EOT
}
