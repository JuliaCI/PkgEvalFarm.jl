# Web submission (broker GET/POST /submit): a person opens a link, signs in with the
# farm's GitHub OAuth app, reviews the run and confirms it in the browser, so tools
# without farm credentials only need to produce the link. GitHub's web flow needs
# the OAuth app's client secret. Like the bot's secrets, the value here is a
# placeholder (a real secret in terraform state is what this design avoids) and web
# submission stays off (503) until it is set out of band:
#
#   aws ssm put-parameter --name /pkgeval/github-client-secret --type SecureString \
#     --value "<client secret>" --overwrite
#
# The OAuth app's "Authorization callback URL" must be
# https://<broker_domain>/submit/callback, and broker_domain must be set (the
# broker builds its redirect URL from it).

locals {
  web_submit_enabled = var.github_client_secret_parameter == "" ? 0 : 1
}

resource "aws_ssm_parameter" "github_client_secret" {
  count       = local.web_submit_enabled
  name        = var.github_client_secret_parameter
  description = "Client secret of the farm's GitHub OAuth app (broker web submission)"
  type        = "SecureString"
  value       = "placeholder-set-out-of-band"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_iam_role_policy" "broker_client_secret" {
  count = local.web_submit_enabled
  name  = "read-client-secret"
  role  = aws_iam_role.broker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [aws_ssm_parameter.github_client_secret[0].arn]
      }
    ]
  })
}
