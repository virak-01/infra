output "control_plane_id" {
  description = "Instance ID of the control plane. Used by scripts/get-kubeconfig.sh for Session Manager access."
  value       = aws_instance.control_plane.id
}

output "control_plane_public_ip" {
  description = "Public IP of the control plane. Empty when associate_public_ip is false."
  value       = aws_instance.control_plane.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP the API server advertises to the cluster."
  value       = aws_instance.control_plane.private_ip
}

output "worker_ids" {
  description = "Instance IDs of the workers."
  value       = aws_instance.worker[*].id
}

output "worker_public_ips" {
  description = "Public IPs of the workers. Ingress NodePort traffic arrives here."
  value       = aws_instance.worker[*].public_ip
}

output "worker_private_ips" {
  description = "Private IPs of the workers."
  value       = aws_instance.worker[*].private_ip
}

output "ami_id" {
  description = "AMI actually used. Pin this in tfvars for reproducible rebuilds."
  value       = local.ami_id
}

output "join_command_parameter_name" {
  description = "SSM path holding the join command. The VALUE is never an output — that would place a live credential in Terraform state and in any CI log that prints outputs."
  value       = aws_ssm_parameter.join_command.name
}

output "kubernetes_version" {
  description = "Kubernetes minor version installed on the nodes."
  value       = var.kubernetes_version
}
