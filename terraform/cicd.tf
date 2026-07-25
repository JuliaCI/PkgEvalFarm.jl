# CI/CD: GitHub Actions authenticates via OIDC (no stored AWS credentials) and
# is allowed to publish new Lambda bundles — nothing else.
#
# Division of ownership: terraform owns infrastructure and *bootstraps* the
# initial code bundles; CI owns code updates thereafter (see the ignore_changes
# lifecycle blocks on the zip objects and functions).
#
# Two IAM rules govern what this trust policy may contain; violating either
# yields the same unhelpful "Not authorized to perform
# sts:AssumeRoleWithWebIdentity", with no indication of which condition failed:
#
#  1. GitHub Actions is a *shared* OIDC provider, so IAM requires the
#     identity-provider control `token.actions.githubusercontent.com:sub` to be
#     evaluated (and not as a bare wildcard). A policy that pins only the
#     GitHub-specific claims and omits `sub` is unassumable.
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_oidc_secure-by-default.html
#  2. Only a fixed set of GitHub claims map to condition keys: actor, actor_id,
#     job_workflow_ref, repository, repository_id, repository_owner_id,
#     workflow, ref, environment, enterprise_id (plus aud/sub/amr). Conditions
#     on anything else — event_name, runner_environment, repository_owner,
#     workflow_ref — can never match.
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html#condition-keys-wif

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
        Condition = merge({
          StringEquals = merge(
            # a token minted for another audience cannot be replayed here
            { "${local.oidc}:aud" = "sts.amazonaws.com" },
            # the repository and its owner, by immutable numeric id: these
            # survive renames and cannot be re-claimed by registering the same
            # path after a deletion
            var.github_repository_id == null ? {} :
            { "${local.oidc}:repository_id" = var.github_repository_id },
            var.github_repository_owner_id == null ? {} :
            { "${local.oidc}:repository_owner_id" = var.github_repository_owner_id },
            # the branch. Also excludes pull requests, whose ref is
            # refs/pull/N/merge — including PRs from forks, which run in this
            # repo's context but with the fork's workflow file. (GitHub also
            # caps fork-PR permissions at read-only, so such a job cannot mint
            # a token at all.)
            var.github_deploy_ref == null ? {} :
            { "${local.oidc}:ref" = var.github_deploy_ref },
            # the exact workflow file: a *new* workflow added to the branch
            # does not inherit this grant
            var.github_deploy_workflow_ref == null ? {} :
            { "${local.oidc}:job_workflow_ref" = var.github_deploy_workflow_ref },
          )
          },
          length(var.github_deploy_subjects) == 0 ? {} : {
            StringLike = {
              # This org emits the *immutable* subject format, which embeds the
              # numeric owner and repository ids:
              #   repo:OWNER@<owner_id>/REPO@<repo_id>:ref:refs/heads/master
              # so a single condition pins the repository (immune to renames and
              # to the path being re-registered by someone else) *and* the branch.
              # Pull requests — including from forks, which run in this repo's
              # context but with the fork's workflow file — end in `:pull_request`
              # rather than `:ref:refs/heads/master`, so they cannot match.
              # Verify the exact string your org mints before changing this; see
              # the claim-dump snippet in README.md.
              "${local.oidc}:sub" = var.github_deploy_subjects
            }
        })
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
