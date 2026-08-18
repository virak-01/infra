# One control-plane instance and N workers, each bootstrapped by cloud-init.
#
# The bootstrap scripts live in kubernetes/bootstrap/ as ordinary executable files
# rather than as heredocs inside Terraform. That way they can be run by hand on a
# node that failed, tested with shellcheck, and reviewed as shell — and there is
# exactly one copy of each, not one for user-data and one for the runbook.

data "aws_region" "current" {}

# Latest Canonical Ubuntu 22.04 LTS for this region, unless an AMI was pinned.
# owners is the canonical account id and is what makes this safe: filtering on name
# alone would match an image published by anyone.
data "aws_ami" "ubuntu" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

locals {
  ami_id                = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu[0].id
  control_plane_type    = var.control_plane_instance_type != null ? var.control_plane_instance_type : var.instance_type
  # <repo>/script/bootstrap — three directories up from terraform/modules/ec2.
  # The scripts stay ordinary executable files rather than heredocs inside Terraform,
  # so they can be run by hand on a node that failed and checked with shellcheck.
  bootstrap_dir         = "${path.module}/../../../script/bootstrap"
  shared_install_script = file("${local.bootstrap_dir}/install-containerd.sh")

  # Substituted into both scripts. Every value is non-secret: a parameter NAME, a
  # region, a CIDR. The token itself never appears in user-data — user-data is
  # readable through IMDS by any process on the instance, so a token placed here
  # would be readable by every container on the node.
  script_vars = {
    K8S_MINOR        = var.kubernetes_version
    POD_CIDR         = var.pod_cidr
    JOIN_PARAM       = var.join_command_parameter_name
    AWS_REGION       = data.aws_region.current.name
    CNI_MANIFEST_URL = var.cni_manifest_url
    TOKEN_TTL        = var.join_token_ttl
    NODE_USER        = var.node_user
  }

  # The scripts `source` install-containerd.sh from their own directory, so
  # user-data has to lay it down next to them before running. Written to a stable
  # path so a later manual re-run finds it in the same place.
  install_script_b64 = base64encode(local.shared_install_script)
}

# ─── the join param ────────────────────────────────────────────────────────────
#
# Created here with a PLACEHOLDER value. The real join command is written by the
# control plane at boot, using the least-privilege role from the iam module.
#
# ignore_changes on `value` is what makes that work: without it Terraform would see
# the control plane's token as drift and overwrite it with "PENDING" on the next
# apply, silently breaking every future node join.

resource "aws_ssm_parameter" "join_command" {
  name        = var.join_command_parameter_name
  description = "kubeadm join command for ${var.cluster_name}. Written by the control plane, not by Terraform."
  type        = "SecureString"
  value       = "PENDING"

  lifecycle {
    ignore_changes = [value]
  }

  tags = merge(var.tags, { Name = var.join_command_parameter_name })
}

# ─── control plane ─────────────────────────────────────────────────────────────
resource "aws_instance" "control_plane" {
  ami           = local.ami_id
  instance_type = local.control_plane_type
  subnet_id     = var.subnet_ids[0]

  vpc_security_group_ids      = [var.control_plane_security_group_id]
  iam_instance_profile        = var.control_plane_instance_profile
  key_name                    = var.key_name
  associate_public_ip_address = var.associate_public_ip

  # GZIPPED, because EC2 caps user-data at 16 KB and this exceeds it uncompressed.
  # The wrapper embeds both bootstrap scripts base64-encoded, and base64 inflates by a
  # third — the control-plane document renders to ~18 KB and is rejected with
  #
  #   expected length of user_data to be in the range (0 - 16384)
  #
  # cloud-init detects the gzip magic bytes and decompresses on its own, so nothing on
  # the instance changes. Roughly 38% of the original size, which leaves real headroom:
  # the worker document was already at 15.5 KB, one added comment from the same failure.
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/user-data.sh.tftpl", merge(local.script_vars, {
    ROLE               = "control-plane"
    INSTALL_SCRIPT_B64 = local.install_script_b64
    ROLE_SCRIPT_B64    = base64encode(file("${local.bootstrap_dir}/control-plane.sh"))
  })))

  # Changing user-data on an existing instance does nothing — cloud-init runs once,
  # at first boot. Without this, editing a bootstrap script produces an apply that
  # reports success and changes nothing on the node.
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true # etcd lives on this volume: the entire cluster state, including Secrets.

    tags = merge(var.tags, { Name = "${var.name_prefix}-control-plane-root" })
  }

  # IMDSv2 required. IMDSv1 answers an unauthenticated GET, so any SSRF in a pod
  # can read the node's IAM credentials; requiring a token means a request has to be
  # deliberate. The hop limit of 2 is needed for containers to reach IMDS at all —
  # a limit of 1 stops at the host network namespace.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-control-plane"
    Role                                        = "control-plane"
    Environment                                 = var.environment
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# ─── workers ───────────────────────────────────────────────────────────────────
resource "aws_instance" "worker" {
  count = var.worker_count

  ami           = local.ami_id
  instance_type = var.instance_type

  # Round-robin across the supplied subnets, so workers spread across AZs and a
  # single AZ failure does not take every worker.
  subnet_id = var.subnet_ids[count.index % length(var.subnet_ids)]

  vpc_security_group_ids      = [var.worker_security_group_id]
  iam_instance_profile        = var.worker_instance_profile
  key_name                    = var.key_name
  associate_public_ip_address = var.associate_public_ip

  # GZIPPED, because EC2 caps user-data at 16 KB and this exceeds it uncompressed.
  # The wrapper embeds both bootstrap scripts base64-encoded, and base64 inflates by a
  # third — the control-plane document renders to ~18 KB and is rejected with
  #
  #   expected length of user_data to be in the range (0 - 16384)
  #
  # cloud-init detects the gzip magic bytes and decompresses on its own, so nothing on
  # the instance changes. Roughly 38% of the original size, which leaves real headroom:
  # the worker document was already at 15.5 KB, one added comment from the same failure.
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/user-data.sh.tftpl", merge(local.script_vars, {
    ROLE               = "worker"
    INSTALL_SCRIPT_B64 = local.install_script_b64
    ROLE_SCRIPT_B64    = base64encode(file("${local.bootstrap_dir}/worker.sh"))
  })))

  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true

    tags = merge(var.tags, { Name = "${var.name_prefix}-worker-${count.index + 1}-root" })
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-worker-${count.index + 1}"
    Role                                        = "worker"
    Environment                                 = var.environment
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })

  # Orders the API calls only — it cannot wait for kubeadm init to finish inside the
  # control plane. The worker script polls SSM for the join command precisely
  # because Terraform has no way to express "wait until the cluster exists".
  depends_on = [
    aws_instance.control_plane,
    aws_ssm_parameter.join_command,
  ]
}
