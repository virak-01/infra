# ─── dns — inputs ──────────────────────────────────────────────────────────────

variable "domain_name" {
  description = "Apex domain, e.g. devops-selft-learning.xyz."
  type        = string
}

variable "create_zone" {
  description = <<-EOT
    true  — create the hosted zone here. You must then point the registrar at the
            zone's name servers (see the `name_servers` output) or nothing
            resolves and ACM validation never completes.
    false — look up an existing zone by name.
  EOT
  type        = bool
  default     = false
}

variable "subject_alternative_names" {
  description = <<-EOT
    Extra names on the certificate. The wildcard covers uat., uat-api. and api.
    in one certificate, which is what lets UAT and prod share it.

    A wildcard matches ONE label: *.example.com covers uat.example.com but not
    a.b.example.com.
  EOT
  type        = list(string)
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
