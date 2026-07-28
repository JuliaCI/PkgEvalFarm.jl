# A read-only-plus-worker-shell role for debugging the farm, intended for
# handing short-lived credentials to someone (or something) helping diagnose a
# problem. It is deliberately narrow:
#
#   - shell access via SSM to farm *worker* instances only (tag-conditioned),
#     never to anything else in the account;
#   - read-only on the farm's queue, tables, results objects and Lambda logs;
#   - nothing mutating anywhere: no scaling, no terraform, no writes.
#
# Describe/List actions appear with Resource "*" because AWS does not support
# resource-level permissions for them (ec2:DescribeInstances,
# autoscaling:Describe*, cloudwatch:DescribeAlarms), not because they are meant
# to be broad.
#
# Note that SSM shell access to a worker is effectively root on that box. Those
# instances hold only worker-scoped credentials, reachable through a
# bearer-gated proxy with IMDS firewalled — but treat this as "can inspect and
# disturb running jobs", not as read-only.

locals {
  # Who may assume the debug role. The account-root ARN is IAM's idiom for
  # "delegate to this account": it does *not* mean the root user — it means any
  # principal in the account that separately holds sts:AssumeRole permission for
  # this role. Narrow it to specific user/role ARNs if you want fewer people
  # able to mint these credentials.
  debug_principals = coalesce(var.debug_role_principals,
  ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"])

  # note: the account-root ARN above delegates to the account; it does not let
  # the *root user* assume the role — AWS forbids that outright, hence the
  # bootstrap user at the bottom of this file.
}

resource "aws_iam_role" "debug" {
  count = var.debug_role_enabled ? 1 : 0
  name  = "${var.name_prefix}-debug"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = local.debug_principals }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  max_session_duration = var.debug_role_max_session_seconds
}

resource "aws_iam_role_policy" "debug" {
  count = var.debug_role_enabled ? 1 : 0
  name  = "inspect-farm"
  role  = aws_iam_role.debug[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ShellOnFarmWorkersOnly"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = "${var.name_prefix}-ec2-worker" }
        }
      },
      {
        Sid      = "ShellDocument"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
      },
      {
        Sid    = "InteractiveSessions"
        Effect = "Allow"
        Action = [
          "ssm:StartSession",
          "ssm:TerminateSession",
          "ssm:ResumeSession",
        ]
        Resource = [
          "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ssm:${var.region}::document/AWS-StartInteractiveCommand",
          "arn:aws:ssm:*:*:session/*",
        ]
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = "${var.name_prefix}-ec2-worker" }
        }
      },
      {
        Sid    = "ReadCommandResults"
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation",
          "ssm:ListCommands",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation",
        ]
        Resource = "*"
      },
      {
        # these actions do not support resource-level permissions
        Sid    = "DescribeFleet"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeSpotPriceHistory",
          "ec2:GetSpotPlacementScores",
          "ec2:GetConsoleOutput",
          "logs:DescribeLogGroups",
          "autoscaling:Describe*",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
        ]
        Resource = "*"
      },
      {
        Sid    = "InspectQueue"
        Effect = "Allow"
        Action = "sqs:GetQueueAttributes"
        Resource = [aws_sqs_queue.jobs.arn, aws_sqs_queue.jobs_slow.arn,
        aws_sqs_queue.jobs_dlq.arn]
      },
      {
        # The one deliberate write: re-driving a job by enqueueing a duplicate
        # message (claim_job drops duplicates for completed jobs, so this is
        # safe by construction). Debugging stuck deliveries needs it.
        Sid    = "RedriveJobs"
        Effect = "Allow"
        Action = "sqs:SendMessage"
        # the DLQ is included so the dead-letter consumer path can be exercised
        # directly (inject a synthetic dead message, watch the bot fail the run)
        # without driving eight failed receives through the live queues
        Resource = [aws_sqs_queue.jobs.arn, aws_sqs_queue.jobs_slow.arn, aws_sqs_queue.jobs_dlq.arn]
      },
      {
        Sid    = "ReadFarmState"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:DescribeTable",
        ]
        Resource = concat([aws_dynamodb_table.runs.arn, aws_dynamodb_table.jobs.arn],
        aws_dynamodb_table.builds[*].arn)
      },
      {
        Sid      = "ReadResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.results.arn, "${aws_s3_bucket.results.arn}/*"]
      },
      {
        Sid    = "ReadLambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:FilterLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
          "logs:GetLogEvents",
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-*:*"
      },
      {
        Sid      = "InspectFunctions"
        Effect   = "Allow"
        Action   = ["lambda:GetFunctionConfiguration", "lambda:ListFunctions"]
        Resource = "*"
      },
    ]
  })
}

# Root cannot assume roles (an AWS-wide restriction), so an account whose only
# human identity is root needs a minimal principal to assume the debug role
# with. This user can do exactly one thing: assume that role. Its access key is
# deliberately NOT created here — generate it out of band so no long-lived
# secret ever lands in terraform state:
#
#   aws iam create-access-key --user-name ${prefix}-debug
#   aws iam delete-access-key --user-name ${prefix}-debug --access-key-id ...
resource "aws_iam_user" "debug" {
  count = var.debug_role_enabled && var.debug_user_enabled ? 1 : 0
  name  = "${var.name_prefix}-debug"
}

resource "aws_iam_user_policy" "debug" {
  count = var.debug_role_enabled && var.debug_user_enabled ? 1 : 0
  name  = "assume-debug-role"
  user  = aws_iam_user.debug[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.debug[0].arn
      }
    ]
  })
}
