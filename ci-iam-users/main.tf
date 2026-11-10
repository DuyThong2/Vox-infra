provider "aws" {
  region = var.region
}

# Neither user below gets any eks:* permission on purpose -- deployment is
# GitOps (CI's job ends at pushing to ECR + committing the new image tag to
# vox-helm; ArgoCD running inside the cluster picks it up via its own
# in-cluster RBAC, not AWS IAM). Pulling images onto nodes is the EKS node
# group role's job (ECR read policy attached in Phase 2 of
# task/deploy-structure/execution-plan.md), not these CI users'.

data "aws_caller_identity" "current" {}

locals {
  fe_bucket_name = "${var.fe_name}-spa-${replace(var.fe_domain_name, ".", "-")}"
}

# -----------------------------------------------------------------------------
# User 1 -- shared by the 3 repos under the "vientrlenh" GitHub account:
#   vox            -> push to ECR repo var.ecr_repo_vox
#   vox-streaming  -> push to ECR repo var.ecr_repo_vox_streaming
#   vox-client-web -> sync SPA build to the FE S3 bucket + CloudFront invalidation
#                     (no CI/CD workflow uses this anymore -- deploy is manual
#                     from the user's machine, see runbook.md section 8 -- kept
#                     here anyway as a ready-made scoped credential in case the
#                     user wants to use it for the manual sync instead of their
#                     own admin credentials)
# -----------------------------------------------------------------------------
resource "aws_iam_user" "vientrlenh" {
  name = "github-actions-vientrlenh"
  path = "/ci/"

  tags = {
    Purpose = "GitHub Actions CI - vox / vox-streaming / vox-client-web - vientrlenh account"
  }
}

resource "aws_iam_access_key" "vientrlenh" {
  user = aws_iam_user.vientrlenh.name
}

data "aws_iam_policy_document" "vientrlenh" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken does not support resource-level scoping
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repo_vox}",
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repo_vox_streaming}",
    ]
  }

  statement {
    sid = "FrontendDeploy"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${local.fe_bucket_name}",
      "arn:aws:s3:::${local.fe_bucket_name}/*",
    ]
  }

  statement {
    sid       = "FrontendCacheInvalidate"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = ["arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"] # distribution ID not known until infrastructureFE is applied
  }
}

resource "aws_iam_user_policy" "vientrlenh" {
  name   = "github-actions-vientrlenh-policy"
  user   = aws_iam_user.vientrlenh.name
  policy = data.aws_iam_policy_document.vientrlenh.json
}

# -----------------------------------------------------------------------------
# User 2 -- "agents" repo only, lives under a DIFFERENT GitHub account
# (DuyThong2/Voxenta-Agentic-AI), kept as its own IAM user so it can't touch
# the other two ECR repos or the FE bucket.
# -----------------------------------------------------------------------------
resource "aws_iam_user" "duythong2" {
  name = "github-actions-duythong2"
  path = "/ci/"

  tags = {
    Purpose = "GitHub Actions CI - agents / Voxenta-Agentic-AI - DuyThong2 account"
  }
}

resource "aws_iam_access_key" "duythong2" {
  user = aws_iam_user.duythong2.name
}

data "aws_iam_policy_document" "duythong2" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repo_agents}",
    ]
  }
}

resource "aws_iam_user_policy" "duythong2" {
  name   = "github-actions-duythong2-policy"
  user   = aws_iam_user.duythong2.name
  policy = data.aws_iam_policy_document.duythong2.json
}
