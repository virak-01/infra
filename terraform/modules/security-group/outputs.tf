output "control_plane_security_group_id" {
  description = "Attach to the control-plane EC2 instance."
  value       = aws_security_group.control_plane.id
}

output "worker_security_group_id" {
  description = "Attach to every worker EC2 instance."
  value       = aws_security_group.worker.id
}

output "nodeport_allowed_cidrs" {
  description = "CIDRs that can actually reach the NodePort range, after the fallback to ssh_allowed_cidrs."
  value       = local.nodeport_cidrs
}
