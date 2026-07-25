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
          # `aud` is pinned so a token minted for some other audience can't be
          # replayed here; `repository_id` is the numeric repo id, which (unlike
          # the name in `sub`) survives renames and cannot be re-claimed by
          # deleting and re-creating a repo with the same path.
          StringEquals = merge(
            { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" },
            var.github_repository_id == null ? {} :
            { "token.actions.githubusercontent.com:repository_id" = var.github_repository_id },
            # the exact workflow file that may deploy: a *new* workflow added to
            # master (or a reusable workflow called from elsewhere) does not
            # inherit this grant
            var.github_deploy_workflow_ref == null ? {} :
            { "token.actions.githubusercontent.com:job_workflow_ref" = var.github_deploy_workflow_ref },
            # the trigger: only a push, so workflow_dispatch/schedule/PR runs of
            # the same file cannot deploy (mirrors the job's own `if:`)
            var.github_deploy_event_name == null ? {} :
            { "token.actions.githubusercontent.com:event_name" = var.github_deploy_event_name },
            # refuse tokens minted on self-hosted runners, whose environment is
            # not controlled by GitHub
            var.github_require_hosted_runner ?
            { "token.actions.githubusercontent.com:runner_environment" = "github-hosted" } : {}
          )
          # `sub` encodes repo + trigger context. A push to master is
          #   repo:OWNER/REPO:ref:refs/heads/master
          # while a pull request — including one from a fork, which runs in this
          # repo's context with the *fork's* workflow file — is
          #   repo:OWNER/REPO:pull_request
          # so fork PRs cannot match this condition even if they could mint a
          # token (GitHub also caps fork-PR permissions at read-only, so
          # `id-token: write` is unavailable to them in the first place).
          # NOTE: a job with `environment: X` gets sub `repo:OWNER/REPO:environment:X`
          # instead — if you add an environment to the deploy job, this must change.
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
