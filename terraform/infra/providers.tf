# Terraform and provider configuration for the infra stack.
# Backend configuration lives in backend.tf; inputs in main.tf.

terraform {
  required_version = ">= 1.10" # use_lockfile in backend.tf needs 1.10+
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Applied to every taggable resource. `Stack` is what lets you find or clean up
  # everything this state file owns without reading the state.
  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "aws-kubernetes"
      Cluster   = var.cluster_name
    }
  }
}
