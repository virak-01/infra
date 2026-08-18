# ─── registry — inputs ─────────────────────────────────────────────────────────

variable "repositories" {
  description = <<-EOT
    Repository names. Must match the `newName:` suffixes in both overlays —
    website (serves /), core (/api) and auth (/api/auth, /api/health).
  EOT
  type        = list(string)
  default     = ["website", "core", "auth"]
}

variable "immutable_tags" {
  description = <<-EOT
    IMMUTABLE rejects a push that reuses an existing tag.

    Worth the friction. The manifests repo's rule is never reuse a tag, because
    nodes cache layers — so one tag can mean two different images across the
    fleet, and a rollback to it lands somewhere undefined. This makes that a
    push-time error instead of a mystery later.
  EOT
  type        = bool
  default     = true
}

variable "untagged_expiry_days" {
  description = "Delete untagged images after this many days. They are unreferenced layers from overwritten or failed pushes."
  type        = number
  default     = 7
}

variable "keep_tagged_images" {
  description = <<-EOT
    How many tagged images to retain per repository.

    This is a rollback horizon, not a storage setting: an image expired from here
    cannot be rolled back to, however far back the git history goes.
  EOT
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
