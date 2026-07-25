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

  oidc = "token.actions.githubusercontent.com"

  # Claims a deploy token must carry. Everything here is exact-match; see
  # `.github/workflows/ci.yml` for the corresponding job-level guards.
  deploy_claims = merge(
    # a token minted for another audience cannot be replayed against AWS
    { "${local.oidc}:aud" = "sts.amazonaws.com" },
    # the repository, by immutable numeric id: survives renames and cannot be
    # re-claimed by deleting the repo and re-registering the same path
    var.github_repository_id == null ? {} :
    { "${local.oidc}:repository_id" = var.github_repository_id },
    # the branch. Pinned via `ref` rather than `sub`, because the *format* of
    # `sub` is org-configurable: with the immutable variant enabled it reads
    # repo:OWNER@<id>/REPO@<id>:ref:... and silently stops matching a policy
    # written against the documented repo:OWNER/REPO:ref:... form.
    var.github_deploy_ref == null ? {} :
    { "${local.oidc}:ref" = var.github_deploy_ref },
    # the exact workflow file: a *new* workflow added to the branch (or a
    # reusable workflow called from elsewhere) does not inherit this grant
    var.github_deploy_workflow_ref == null ? {} :
    { "${local.oidc}:job_workflow_ref" = var.github_deploy_workflow_ref },
    # the trigger: only a push, so workflow_dispatch/schedule/pull_request runs
    # of the very same file cannot deploy. Pull requests — including those from
    # forks, which run in this repo's context but with the fork's workflow file
    # — carry event_name=pull_request and a refs/pull/N/merge ref, so they match
    # neither this nor the ref condition. (GitHub also caps fork-PR permissions
    # at read-only, so such a job cannot mint a token in the first place.)
    var.github_deploy_event_name == null ? {} :
    { "${local.oidc}:event_name" = var.github_deploy_event_name },
    # refuse tokens minted on self-hosted runners, whose environment is not
    # controlled by GitHub
    var.github_require_hosted_runner ?
    { "${local.oidc}:runner_environment" = "github-hosted" } : {},
  )

  # `sub` is opt-in only (see github_deploy_subjects); the claims above are
  # strictly more precise and do not depend on its format.
  deploy_condition = merge(
    { StringEquals = local.deploy_claims },
    length(var.github_deploy_subjects) == 0 ? {} :
    { StringLike = { "${local.oidc}:sub" = var.github_deploy_subjects } },
  )
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
        Condition = local.deploy_condition
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
