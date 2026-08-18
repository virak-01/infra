# ─── registry — outputs ────────────────────────────────────────────────────────

output "repository_urls" {
  description = "Map of repo name to pull URL. The overlays' `newName:` values."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "registry_host" {
  description = "The <acct>.dkr.ecr.<region>.amazonaws.com prefix shared by all repos."
  value       = length(var.repositories) > 0 ? split("/", values(aws_ecr_repository.this)[0].repository_url)[0] : ""
}
