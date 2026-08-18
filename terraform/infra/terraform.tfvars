# Copy to terraform.tfvars and edit. tfvars files are gitignored — they name your
# account's domain and, if you narrow the API endpoint, your office addresses.

region       = "us-east-1"
cluster_name = "bubernestes"

# Must match the Cluster Autoscaler image minor in the manifests repo
# (k8s/cluster/aws/cluster-autoscaler/deployment.yaml pins v1.31.1).
kubernetes_version = "1.31"

# A NEW range, deliberately not the default VPC's 172.31.0.0/16 that the
# hand-built cluster used — so this stack and that cluster can run side by side
# during the migration. Whatever you set here has to be written into the
# NetworkPolicy in k8s/components/ingress-alb.
vpc_cidr = "10.20.0.0/16"

# An ALB needs at least two AZs. Three costs nothing extra for the load balancer
# itself and gives the node group somewhere to go when one AZ is short on
# capacity.
az_count = 3

# true = one NAT gateway (~$32/mo, single AZ of egress).
# false = one per AZ (~$32/mo each, survives an AZ loss).
single_nat_gateway = true

# ---------------------------------------------------------------------------
# DNS. Set domain_name = null to skip the zone and certificate entirely; then
# also remove the certificate-arn and ssl-redirect annotations from
# k8s/components/ingress-alb, or every request is redirected to HTTPS and fails
# certificate validation against the ALB's own hostname.
#
# create_zone = false looks up an existing zone by this name.
# create_zone = true creates one — you must then point the registrar at the
# `zone_name_servers` output, or ACM validation never completes.
# ---------------------------------------------------------------------------
# null skips the hosted zone and certificate entirely, and the ALB is reachable by its
# own hostname over HTTP. That is the only value that works on an account with no
# domain — with create_zone = false the dns module does a Route 53 LOOKUP, and a domain
# you do not own fails the apply with "no matching Route53Zone found".
#
# Set a real domain here once you own one, and remember the certificate-arn and
# ssl-redirect annotations in k8s/components/ingress-alb only make sense with it.
domain_name = null
create_zone = false

# ---------------------------------------------------------------------------
# Nodes. t3.medium is 2 vCPU / 4 GiB; the four workloads request 200m and 256Mi
# each, so two nodes hold both namespaces with headroom.
#
# node_max_size is the HARD ceiling — the Cluster Autoscaler can never exceed it.
# ---------------------------------------------------------------------------
node_instance_types = ["t3.medium", "t3a.medium"]
node_min_size       = 2
node_max_size       = 6

# NARROW THIS. The default leaves the Kubernetes API endpoint reachable from the
# internet — still authenticated, but reachable. Your office or VPN range:
#   public_access_cidrs = ["203.0.113.4/32"]
public_access_cidrs = ["0.0.0.0/0"]
