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
# WORKS AGAINST EITHER CLUSTER STACK. `cluster_stack` selects which one, and that
# changes three things:
#
#   which state it reads   ../infra or ../infra-kubeadm
#   how it authenticates   EKS issues a token through the AWS API; kubeadm has no such
#                          endpoint, so the providers use your kubeconfig instead
#   what it installs       the AWS-integrated controllers need IRSA, which only exists
#                          on EKS. On kubeadm they default OFF and ingress-nginx
#                          defaults ON — see the enable_* variables.
#
# Read in this order:
#   1. cd ../infra           && terraform apply     (or ../infra-kubeadm)
#   2. get a working kubectl — `aws eks update-kubeconfig`, or fetch admin.conf
#   3. cd ../platform        && terraform apply
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

variable "cluster_stack" {
  description = <<-EOT
    Which cluster stack this platform sits on: "infra" (EKS) or "infra-kubeadm".

    Selects the remote state to read AND how the providers authenticate. Getting it
    wrong shows up as "Unauthorized" from the Kubernetes API rather than as a
    configuration error, because the provider happily builds with the wrong credentials.
  EOT
  type        = string
  default     = "infra"

  validation {
    condition     = contains(["infra", "infra-kubeadm"], var.cluster_stack)
    error_message = "cluster_stack must be \"infra\" or \"infra-kubeadm\"."
  }
}

variable "kubeconfig_path" {
  description = <<-EOT
    Kubeconfig used when cluster_stack is "infra-kubeadm".

    kubeadm has no AWS API that issues cluster tokens, so there is nothing for the
    provider to call — it uses the same file kubectl does. Fetch it from the control
    plane first, or this fails with "connection refused" against localhost:8080, which
    is the provider's default when it has no configuration at all.
  EOT
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "Context within kubeconfig_path. Null uses the current-context."
  type        = string
  default     = null
}

# ─── which controllers to install ─────────────────────────────────────────────
#
# Null means "decide from cluster_stack" — see locals below. The AWS-integrated three
# need credentials that only IRSA supplies cleanly, so they are EKS-only by default.
# Forcing them on for kubeadm is possible but means putting AWS credentials on the node
# role, which the egress NetworkPolicy in k8s/ deliberately blocks access to.

variable "enable_alb_controller" {
  description = "AWS Load Balancer Controller. Null = on for EKS, off for kubeadm."
  type        = bool
  default     = null
}

variable "enable_external_dns" {
  description = "external-dns. Null = on for EKS, off for kubeadm."
  type        = bool
  default     = null
}

variable "enable_cluster_autoscaler" {
  description = "Cluster Autoscaler. Null = on for EKS, off for kubeadm (its ASG is the node group)."
  type        = bool
  default     = null
}

variable "enable_ingress_nginx" {
  description = <<-EOT
    ingress-nginx. Null = OFF for EKS, ON for kubeadm.

    The kubeadm path has no ALB controller, so this is how an Ingress gets served at
    all. Published as a NodePort Service, which is what the worker security group's
    30000-32767 rule admits.
  EOT
  type        = bool
  default     = null
}

variable "enable_metrics_server" {
  description = "metrics-server. On for both — every HPA reports <unknown> without it."
  type        = bool
  default     = true
}

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx chart version. Only used when enable_ingress_nginx resolves true."
  type        = string
  default     = "4.11.3"
}

variable "alb_controller_chart_version" {
  description = "Keep the controller image in step with the IAM policy fetched by script/fetch-policies.sh (LBC_VERSION)."
  type        = string
  default     = "1.8.2"
}

# ─── the cluster stack's outputs ──────────────────────────────────────────────
#
# The key is interpolated, which a data source permits — unlike a backend block, which
# Terraform reads before evaluating anything and so cannot take variables at all.
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.cluster_stack}/terraform.tfstate"
    region = var.region
  }
}

locals {
  is_eks       = var.cluster_stack == "infra"
  cluster_name = data.terraform_remote_state.cluster.outputs.cluster_name

  # try(), because infra-kubeadm has no IRSA roles to output. A direct reference would
  # fail at plan time with "unsupported attribute" rather than degrading.
  irsa = try(data.terraform_remote_state.cluster.outputs.irsa_role_arns, {})

  # Defaults derived from the stack, overridable per release.
  install = {
    alb_controller     = coalesce(var.enable_alb_controller, local.is_eks)
    external_dns       = coalesce(var.enable_external_dns, local.is_eks)
    cluster_autoscaler = coalesce(var.enable_cluster_autoscaler, local.is_eks)
    ingress_nginx      = coalesce(var.enable_ingress_nginx, !local.is_eks)
    metrics_server     = var.enable_metrics_server
  }
}

# EKS ONLY. Read live rather than from state: the endpoint and CA data are attributes
# that can change without this state file being refreshed. There is no equivalent for
# kubeadm — no AWS API knows about that cluster — so these are skipped and the
# providers fall back to the kubeconfig.
data "aws_eks_cluster" "this" {
  count = local.is_eks ? 1 : 0
  name  = local.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  count = local.is_eks ? 1 : 0
  name  = local.cluster_name
}

# ─── aws load balancer controller ──────────────────────────────────────────────
resource "helm_release" "alb_controller" {
  count = local.install.alb_controller ? 1 : 0

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
  # Only on EKS. try() above leaves local.irsa empty for kubeadm, and annotating a
  # ServiceAccount with a role that does not exist makes the controller fail at its
  # first AWS call rather than at install.
  dynamic "set" {
    for_each = try(local.irsa.alb_controller, null) != null ? [1] : []
    content {
      name  = "serviceAccount.annotations.eks\.amazonaws\.com/role-arn"
      value = local.irsa.alb_controller
    }
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

# ─── external-dns ──────────────────────────────────────────────────────────────
resource "helm_release" "external_dns" {
  count = local.install.external_dns ? 1 : 0

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
  # Only on EKS. try() above leaves local.irsa empty for kubeadm, and annotating a
  # ServiceAccount with a role that does not exist makes the controller fail at its
  # first AWS call rather than at install.
  dynamic "set" {
    for_each = try(local.irsa.external_dns, null) != null ? [1] : []
    content {
      name  = "serviceAccount.annotations.eks\.amazonaws\.com/role-arn"
      value = local.irsa.external_dns
    }
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

# ─── metrics-server ────────────────────────────────────────────────────────────
resource "helm_release" "metrics_server" {
  count = local.install.metrics_server ? 1 : 0

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

# ─── cluster autoscaler ────────────────────────────────────────────────────────
#
# Installed by HELM here rather than by the manifests repo's
# k8s/cluster/aws/cluster-autoscaler, which cannot work on EKS: that Deployment
# pins itself to a control-plane node with a nodeSelector, and EKS control-plane
# nodes are not in your cluster — the pod stays Pending forever with no event
# naming the cause. Delete that directory from the manifests repo, or leave it for
# a future kubeadm cluster and never run `make cluster` against this one.

resource "helm_release" "cluster_autoscaler" {
  count = local.install.cluster_autoscaler ? 1 : 0

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
  dynamic "set" {
    for_each = try(local.irsa.autoscaler, null) != null ? [1] : []
    content {
      name  = "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn"
      value = local.irsa.autoscaler
    }
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

# ─── outputs ───────────────────────────────────────────────────────────────────
# ─── ingress-nginx ────────────────────────────────────────────────────────────
#
# The kubeadm path has no ALB controller, so without this an Ingress object is inert:
# accepted by the API server, claimed by nothing, no address and no error.
#
# NodePort rather than LoadBalancer. Nothing on a kubeadm cluster fulfils a
# LoadBalancer Service, so it would sit at EXTERNAL-IP <pending> forever — and the
# worker security group already admits 30000-32767 for exactly this.
resource "helm_release" "ingress_nginx" {
  count = local.install.ingress_nginx ? 1 : 0

  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true

  set {
    name  = "controller.service.type"
    value = "NodePort"
  }

  # Pinned so the port survives a chart upgrade — it is in the security group rule and
  # in every URL anyone has bookmarked.
  set {
    name  = "controller.service.nodePorts.http"
    value = "30080"
  }
  set {
    name  = "controller.service.nodePorts.https"
    value = "30443"
  }

  # The real client address rather than the node's. Without it every access log and
  # every rate limit sees kube-proxy.
  set {
    name  = "controller.config.use-forwarded-headers"
    value = "true"
  }

  # Two replicas: this controller is in the path of every request, so a single one
  # makes a node drain an outage.
  set {
    name  = "controller.replicaCount"
    value = "2"
  }
}

output "installed" {
  description = "Chart version per controller; null for anything this stack does not install."
  value = {
    alb_controller     = one(helm_release.alb_controller[*].version)
    external_dns       = one(helm_release.external_dns[*].version)
    metrics_server     = one(helm_release.metrics_server[*].version)
    cluster_autoscaler = one(helm_release.cluster_autoscaler[*].version)
    ingress_nginx      = one(helm_release.ingress_nginx[*].version)
  }
}

output "cluster_stack" {
  description = "Which cluster stack these controllers were installed against."
  value       = var.cluster_stack
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
