# THE NETWORK, and the tags that make the load balancer possible.
#
# The AWS Load Balancer Controller does not take a subnet list. It DISCOVERS
# subnets by tag, and fails with `couldn't auto-discover subnets` when it finds
# none — an error that says nothing about tags. Those tags are the single most
# load-bearing thing in this module; see `public` and `private` below.
#
# This module creates a NEW VPC. It deliberately does not adopt the account's
# default VPC (172.31.0.0/16), which is what the hand-built cluster used: a
# default VPC has no private subnets, no NAT, and Terraform adopting it would put
# the existing cluster's network under this state file. Running both side by side
# is the safer migration.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

# ----------------------------------------------------------------------- inputs

variable "name" {
  description = "Name prefix for every resource here."
  type        = string
}

variable "cluster_name" {
  description = <<-EOT
    EKS cluster name. Used only for the `kubernetes.io/cluster/<name>` subnet tag.
    Optional for the load balancer controller since Kubernetes 1.19, kept because
    it is still what most troubleshooting docs tell you to check.
  EOT
  type        = string
}

variable "vpc_cidr" {
  description = <<-EOT
    VPC CIDR. This value ALSO has to be written into the cluster manifests: the
    NetworkPolicy in k8s/components/ingress-alb allows node-sourced traffic from
    this range, because an ALB with instance targets arrives from a node address.
    It is exposed as the `vpc_cidr` output for exactly that reason.
  EOT
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be valid CIDR notation, e.g. 10.20.0.0/16."
  }
}

variable "az_count" {
  description = <<-EOT
    Availability Zones to spread across. An ALB requires at least two, even for a
    single-node cluster — it will not provision in one AZ.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6 (an ALB needs at least 2)."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    true  — one NAT gateway shared by every private subnet (~$32/mo, one AZ of
            egress is a single point of failure).
    false — one per AZ (~$32/mo each, survives an AZ loss).

    true is the right default for a learning platform; flip it before anything
    depends on private-subnet egress staying up.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged onto everything."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------- discovery

data "aws_availability_zones" "available" {
  state = "available"

  # Local Zones and Wavelength zones cannot host EKS nodes and would be selected
  # by index otherwise.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /20 per subnet out of a /16: 4096 addresses each, room for VPC-CNI pod IPs.
  # The VPC CNI assigns pod addresses FROM THE SUBNET, so node subnets size the
  # pod capacity of the cluster — a /24 here would cap the cluster at a couple of
  # hundred pods regardless of instance type.
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  nat_count = var.single_nat_gateway ? 1 : var.az_count
}

# ------------------------------------------------------------------------- vpc

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are REQUIRED by EKS. Without DNS hostnames the kubelet cannot resolve
  # the API endpoint and nodes never join — with no error that mentions DNS.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = var.name })
}

# --------------------------------------------------------------------- subnets

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    Tier = "public"

    # THE DISCOVERY TAG. The controller places an internet-facing ALB only in
    # subnets carrying this. Tag every AZ, not the minimum two: an ALB delivers
    # only to nodes in an AZ enabled on the load balancer, so a node in an
    # un-enabled AZ registers successfully and then sits permanently `unused`,
    # which reads as a broken app rather than a placement problem. A six-AZ ALB
    # costs the same as a two-AZ one.
    "kubernetes.io/role/elb" = "1"

    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
    Tier = "private"

    # The internal counterpart. Nodes live here, so this is also what an
    # internal-facing Ingress would discover.
    "kubernetes.io/role/internal-elb" = "1"

    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ------------------------------------------------------------------------- nat

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id

  # In a PUBLIC subnet. A NAT gateway in a private subnet has no route out and
  # fails silently at traffic time rather than at create time.
  subnet_id = aws_subnet.public[count.index].id

  tags       = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })
  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------- routes

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One table per private subnet even when sharing a single NAT, so switching
# `single_nat_gateway` to false later is a route change rather than a
# re-association of every subnet.
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_default" {
  count = var.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# -------------------------------------------------------------- alb sec. group
#
# SEAM: the node security group must admit traffic from the ALB's security group,
# but the controller creates that group itself — so Terraform has no id to point
# a rule at, and the dependency runs the wrong way.
#
# The fix is to own the group here and hand it to the controller instead, with
# this annotation on the Ingress:
#
#   alb.ingress.kubernetes.io/security-groups: <alb_security_group_id output>
#
# Then Terraform owns both ends of the rule, and the controller stops creating a
# group of its own. Without the annotation this group is simply unused and the
# node rule in modules/cluster admits nothing useful.

resource "aws_security_group" "alb" {
  # name_prefix, NOT name. A security group cannot be replaced in place, and
  # `create_before_destroy` below means the replacement is created while the
  # original still exists — two groups, momentarily, which a fixed name makes
  # impossible: AWS rejects it with InvalidGroup.Duplicate and the apply dies
  # halfway. The prefix lets AWS append a unique suffix for the overlap.
  name_prefix = "${var.name}-alb-"
  description = "Ingress ALB. Referenced by alb.ingress.kubernetes.io/security-groups."
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-alb" })

  # Required because the node-group rule in modules/cluster references this
  # group: AWS refuses to delete a group another rule points at, so the new one
  # must exist before the old is removed.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet; ssl-redirect upgrades it to 443."
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet."
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "To node ports in the VPC."
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------- outputs

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Write this into the NetworkPolicy in k8s/components/ingress-alb."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Tagged for internet-facing load balancers."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Where nodes run. Pod IPs come from these ranges under the VPC CNI."
  value       = aws_subnet.private[*].id
}

output "alb_security_group_id" {
  description = "Set as alb.ingress.kubernetes.io/security-groups on the Ingress."
  value       = aws_security_group.alb.id
}

output "azs" {
  value = local.azs
}
