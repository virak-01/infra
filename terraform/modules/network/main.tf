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

# ─── discovery ─────────────────────────────────────────────────────────────────
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

  nat_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.az_count) : 0
}

# ─── vpc ───────────────────────────────────────────────────────────────────────
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

# ─── subnets ───────────────────────────────────────────────────────────────────
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

# ─── nat ───────────────────────────────────────────────────────────────────────
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

# ─── routes ────────────────────────────────────────────────────────────────────
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
  # No NAT means no default route out of the private subnets — and no resource that
  # would reference aws_nat_gateway.this[0], which does not exist.
  count = var.enable_nat_gateway ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
