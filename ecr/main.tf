provider "aws" {
  region = var.region
}

# Deliberately its own Terraform project, separate from infrastructureBE --
# infrastructureBE's EKS cluster + node group get destroyed/recreated between
# test cycles to save GPU cost (see task/deploy-structure/playbook-destroy.md),
# and CI/CD-pushed images living in these repos must survive that cycle
# untouched (no need to re-trigger every repo's CI just to repopulate ECR
# after every redeploy). Keeping ECR in the same state as the cluster would
# only protect it as long as every `terraform destroy` remembers to pass the
# right `-target` flags -- a separate project makes that a non-issue: there is
# no state here that ever gets destroyed as part of the normal cycle.

locals {
  tags = {
    Project = var.name
  }
}

resource "aws_ecr_repository" "repos" {
  for_each = var.repo_names

  name                 = each.key
  image_tag_mutability = "MUTABLE"
  # Not relied on for the normal destroy/redeploy cycle (this project is never
  # destroyed as part of that) -- kept only so a deliberate, one-off full
  # teardown of this project later doesn't get blocked by leftover images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = local.tags
}

# Without this, storage grows forever: CI pushes 1 unique SHA-tagged image per
# build (never reused, Helm points at it) plus a `:latest` tag that gets
# reused -- the previous digest behind `:latest` becomes untagged, not
# deleted. Two rules: untagged images (leftover from `:latest` being
# reassigned, or manual pushes) expire quickly since nothing references them
# by digest; tagged images are capped by count so old SHA-tagged builds don't
# accumulate forever, while still keeping enough history to roll back.
resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = var.repo_names
  repository = aws_ecr_repository.repos[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 3 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 3
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 5 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}
