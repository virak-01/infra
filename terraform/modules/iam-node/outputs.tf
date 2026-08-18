output "control_plane_instance_profile_name" {
  description = "Attach to the control-plane EC2 instance."
  value       = aws_iam_instance_profile.control_plane.name
}

output "worker_instance_profile_name" {
  description = "Attach to every worker EC2 instance."
  value       = aws_iam_instance_profile.worker.name
}

output "control_plane_role_arn" {
  description = "ARN of the control-plane role, for auditing or for adding further policies."
  value       = aws_iam_role.control_plane.arn
}

output "worker_role_arn" {
  description = "ARN of the worker role."
  value       = aws_iam_role.worker.arn
}

output "join_command_parameter_arn" {
  description = "ARN both policies are scoped to. Useful for confirming least privilege in a review."
  value       = local.join_parameter_arn
}
