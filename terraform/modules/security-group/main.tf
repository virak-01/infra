# Two security groups: one for the control plane, one for workers.
#
# Split rather than shared because the two roles genuinely differ — only the
# control plane serves 6443 and etcd, only workers need the NodePort range — and a
# single group would grant every port to every node.
#
# Rules are separate `aws_vpc_security_group_*_rule` resources rather than inline
# `ingress {}` blocks. Inline blocks are authoritative: Terraform removes anything
# it did not create, so a rule added by a controller or by hand disappears on the
# next apply with no warning.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

locals {
  nodeport_cidrs = var.nodeport_allowed_cidrs != null ? var.nodeport_allowed_cidrs : var.ssh_allowed_cidrs
}

# ============================================================== control plane

resource "aws_security_group" "control_plane" {
  name_prefix = "${var.name_prefix}-control-plane-"
  description = "Kubernetes control-plane node"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-control-plane"
    Role = "control-plane"
  })

  # A security group cannot be replaced in place, and the worker group references
  # this one — AWS refuses to delete a group another rule points at. The
  # replacement must therefore exist before the original goes away, which a fixed
  # `name` would make impossible (InvalidGroup.Duplicate mid-apply).
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cp_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.control_plane.id
  description       = "SSH for bootstrap and kubeconfig retrieval"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cp_api_admin" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.control_plane.id
  description       = "kube-apiserver for kubectl from an operator machine"
  cidr_ipv4         = each.value
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

# Workers reach the API server constantly — the kubelet watches it. Referenced by
# security group, not CIDR, so the rule stays correct as nodes are replaced.
resource "aws_vpc_security_group_ingress_rule" "cp_api_from_workers" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "kube-apiserver from worker kubelets"
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
}

# etcd, self-referencing. Single-node today, but without this rule adding a second
# control-plane node fails at etcd peering rather than at join.
resource "aws_vpc_security_group_ingress_rule" "cp_etcd" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "etcd client and peer traffic between control-plane nodes"
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 2379
  to_port                      = 2380
  ip_protocol                  = "tcp"
}

# 10250 kubelet API, 10257 kube-controller-manager, 10259 kube-scheduler.
# `kubectl logs` and `kubectl exec` go control-plane -> kubelet on 10250, so
# without this those commands hang rather than fail clearly.
resource "aws_vpc_security_group_ingress_rule" "cp_kubelet_from_cluster" {
  for_each = {
    kubelet            = { port = 10250 }
    controller_manager = { port = 10257 }
    scheduler          = { port = 10259 }
  }

  security_group_id            = aws_security_group.control_plane.id
  description                  = "${each.key} from within the control plane"
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cp_kubelet_from_workers" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "kubelet API from workers"
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
}

# CNI overlay traffic. Encapsulated pod-to-pod packets arrive as whatever protocol
# the CNI uses — Calico defaults to IP-in-IP (protocol 4) or VXLAN (UDP 4789),
# Flannel to VXLAN — so restricting by port would break pod networking in a way
# that looks like random service timeouts. Scoped to the peer security group, so
# this is node-to-node only and never open to the VPC at large.
resource "aws_vpc_security_group_ingress_rule" "cp_cni_from_workers" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "CNI overlay and pod traffic from workers"
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "cp_cni_self" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "CNI overlay between control-plane nodes"
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "-1"
}

# Outbound is unrestricted: nodes pull packages, container images and the CNI
# manifest during bootstrap. Tightening this is a real hardening step, and it
# requires an inventory of every registry and repository the cluster uses first.
resource "aws_vpc_security_group_egress_rule" "cp_all" {
  security_group_id = aws_security_group.control_plane.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ==================================================================== workers

resource "aws_security_group" "worker" {
  name_prefix = "${var.name_prefix}-worker-"
  description = "Kubernetes worker node"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-worker"
    Role = "worker"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "worker_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.worker.id
  description       = "SSH for bootstrap troubleshooting"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "worker_kubelet" {
  security_group_id            = aws_security_group.worker.id
  description                  = "kubelet API from the control plane (kubectl logs, exec, metrics)"
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
}

# How ingress traffic actually enters the cluster when the ingress controller is
# published as a NodePort Service.
resource "aws_vpc_security_group_ingress_rule" "worker_nodeports" {
  for_each = toset(local.nodeport_cidrs)

  security_group_id = aws_security_group.worker.id
  description       = "NodePort range for the ingress controller"
  cidr_ipv4         = each.value
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "worker_cni_self" {
  security_group_id            = aws_security_group.worker.id
  description                  = "CNI overlay and pod traffic between workers"
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "worker_cni_from_cp" {
  security_group_id            = aws_security_group.worker.id
  description                  = "CNI overlay and pod traffic from the control plane"
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "worker_all" {
  security_group_id = aws_security_group.worker.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
