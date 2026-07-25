# CI/CD: GitHub Actions authenticates via OIDC (no stored AWS credentials) and
# is allowed to publish new Lambda bundles — nothing else.
#
# Division of ownership: terraform owns infrastructure and *bootstraps* the
# initial code bundles; CI owns code updates thereafter (see the ignore_changes
# lifecycle blocks on the zip objects and functions).

resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_oidc_provider_arn == null ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate chain against its own trust store and
  # ignores these, but the API still expects the field
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  github_oidc_arn = coalesce(var.github_oidc_provider_arn,
  try(aws_iam_openid_connect_provider.github[0].arn, null))
}

resource "aws_iam_role" "deploy" {
  name = "${var.name_prefix}-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = local.github_oidc_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # only the deploy branch of the deploy repo — not forks, not PRs
          StringLike = {
            "token.actions.githubusercontent.com:sub" = var.github_deploy_subjects
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "deploy" {
  name = "publish-lambda-bundles"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UploadBundles"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.lambda.arn}/*"
      },
      {
        Sid    = "PublishFunctionCode"
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:GetFunctionConfiguration",
        ]
        Resource = "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${var.name_prefix}-*"
      },
    ]
  })
}
