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
          "autoscaling:Describe*",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
        ]
        Resource = "*"
      },
      {
        Sid      = "InspectQueue"
        Effect   = "Allow"
        Action   = "sqs:GetQueueAttributes"
        Resource = [aws_sqs_queue.jobs.arn, aws_sqs_queue.jobs_dlq.arn]
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
        Resource = [aws_dynamodb_table.runs.arn, aws_dynamodb_table.jobs.arn]
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
