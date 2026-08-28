# -----------------------------------------------------------------------------
# ECR repositories — eks_deployment.md §3. One per container image. Images are
# built/pushed separately (local buildx or AWS CodeBuild); Terraform only owns
# the repositories. force_delete lets `terraform destroy` remove repos that
# still contain images.
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "this" {
  for_each = toset(var.ecr_repositories)

  name = each.value
  # MUTABLE: the build workflow (CodeBuild / local buildx) and the k8s manifests
  # use a floating `:latest` tag, so re-pushing the same tag must overwrite the
  # previous image. IMMUTABLE would reject the second `:latest` push.
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
