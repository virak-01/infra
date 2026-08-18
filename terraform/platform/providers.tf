# Terraform and provider configuration for the platform stack.
# Backend configuration lives in backend.tf; inputs in main.tf.

terraform {
  required_version = ">= 1.10" # use_lockfile in backend.tf needs 1.10+
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

provider "aws" {
  region = var.region
}

# ─── cluster authentication, both ways ────────────────────────────────────────
#
# EKS issues a short-lived token through the AWS API, so the provider needs no file.
# kubeadm has no such endpoint — nothing in AWS knows that cluster exists — so it uses
# the same kubeconfig kubectl does.
#
# Unset attributes are ignored, which is what lets one provider block serve both: on
# EKS `config_path` is null, on kubeadm `host`/`token` are.
#
# If BOTH end up null the provider silently defaults to localhost:8080 and every
# resource fails with "connection refused" — which reads as the cluster being down
# rather than as missing configuration. Check `cluster_stack` first when you see it.

provider "helm" {
  kubernetes {
    host                   = local.is_eks ? data.aws_eks_cluster.this[0].endpoint : null
    cluster_ca_certificate = local.is_eks ? base64decode(data.aws_eks_cluster.this[0].certificate_authority[0].data) : null
    token                  = local.is_eks ? data.aws_eks_cluster_auth.this[0].token : null

    config_path    = local.is_eks ? null : pathexpand(var.kubeconfig_path)
    config_context = local.is_eks ? null : var.kubeconfig_context
  }
}

provider "kubernetes" {
  host                   = local.is_eks ? data.aws_eks_cluster.this[0].endpoint : null
  cluster_ca_certificate = local.is_eks ? base64decode(data.aws_eks_cluster.this[0].certificate_authority[0].data) : null
  token                  = local.is_eks ? data.aws_eks_cluster_auth.this[0].token : null

  config_path    = local.is_eks ? null : pathexpand(var.kubeconfig_path)
  config_context = local.is_eks ? null : var.kubeconfig_context
}
