# The report page's landing view is a live farm dashboard, and its data source
# is the runs table itself: DynamoDB has no anonymous-read primitive (the data
# plane wants SigV4), so a Cognito identity pool with unauthenticated identities
# is the idiom — the page trades a free GetId/GetCredentialsForIdentity call for
# short-lived credentials whose role can do exactly one thing: read the runs
# table. Everything a run item holds (submitter, trigger, configs, counters,
# failure reason) is already public through reports and GitHub comments; if
# open reads ever become a problem, this pool is where authentication slots in.
#
# Gated on public_reports like the bucket policy: a private deployment gets no
# anonymous surface at all.

resource "aws_cognito_identity_pool" "dashboard" {
  count                            = var.public_reports ? 1 : 0
  identity_pool_name               = "${var.name_prefix} dashboard"
  allow_unauthenticated_identities = true
}

resource "aws_iam_role" "dashboard_reader" {
  count = var.public_reports ? 1 : 0
  name  = "${var.name_prefix}-dashboard-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = "cognito-identity.amazonaws.com" }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.dashboard[0].id
          }
          "ForAnyValue:StringLike" = {
            "cognito-identity.amazonaws.com:amr" = "unauthenticated"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "dashboard_reader" {
  count = var.public_reports ? 1 : 0
  name  = "read-runs-table"
  role  = aws_iam_role.dashboard_reader[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRuns"
        Effect   = "Allow"
        Action   = ["dynamodb:Scan", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.runs.arn
      },
      {
        # queue depths for the dashboard's collapsed debug panel: counts
        # only, and the page fetches them exclusively while a human has the
        # panel open
        Sid    = "QueueDepths"
        Effect = "Allow"
        Action = "sqs:GetQueueAttributes"
        Resource = [
          aws_sqs_queue.jobs.arn, aws_sqs_queue.jobs_slow.arn,
          aws_sqs_queue.jobs_seal.arn, aws_sqs_queue.jobs_deriv.arn,
          aws_sqs_queue.jobs_dlq.arn,
        ]
      }
    ]
  })
}

resource "aws_cognito_identity_pool_roles_attachment" "dashboard" {
  count            = var.public_reports ? 1 : 0
  identity_pool_id = aws_cognito_identity_pool.dashboard[0].id

  # no identity providers are configured, so only the unauthenticated role can
  # ever be assumed; "authenticated" maps to the same reader because the
  # attachment API wants the slot filled
  roles = {
    unauthenticated = aws_iam_role.dashboard_reader[0].arn
    authenticated   = aws_iam_role.dashboard_reader[0].arn
  }
}
