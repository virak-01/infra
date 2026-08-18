# Terraform and provider configuration for the infra-kubeadm stack.
# Backend configuration lives in backend.tf; inputs in main.tf.

terraform {
  required_version = ">= 1.10" # use_lockfile in backend.tf needs 1.10+
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "aws-kubernetes-kubeadm"
      Cluster   = var.cluster_name
    }
  }
}
