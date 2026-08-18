# ECR repositories, one per image the overlays name.
#
# UAT and prod share these. The environments differ by TAG, not by repository —
# k8s/overlays/uat and k8s/overlays/prod both point at the same three repos and
# pin different `newTag:` values, which is what makes promotion a one-line edit.
#
# On EKS nothing else is needed for pulls: the node role carries
# AmazonEC2ContainerRegistryReadOnly (see modules/cluster) and the kubelet's
# credential provider mints a token per pull. The `registry-ecr` component in the
# manifests repo — a CronJob re-minting a 12-hour token into a Secret — exists
# only for clusters without that provider and should be dropped from the overlays
# here.

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = each.value
  image_tag_mutability = var.immutable_tags ? "IMMUTABLE" : "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # Scanning findings and the images themselves outlive a `terraform destroy` of
  # the cluster on purpose: the registry is the handoff point from the build
  # pipeline, and tearing down a cluster should not discard released artifacts.
  force_delete = false

  tags = merge(var.tags, { Name = each.value })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  # Rule order is priority order and ECR evaluates lowest first. Untagged images
  # are expired before the tagged-count rule runs, so untagged layers never
  # consume the retention budget meant for releases.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the newest ${var.keep_tagged_images} tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_tagged_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
