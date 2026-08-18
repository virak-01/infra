# ─── Security groups owned by Terraform rather than by a controller. ───────────

# ─── alb sec. group ────────────────────────────────────────────────────────────
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
