# IAM roles. The broker Lambda authenticates users via GitHub (device flow +
# team membership) and then vends temporary credentials by assuming the worker
# or submitter role on their behalf.
#
# Note on ordering: the worker/submitter trust policies reference the broker
# role's ARN, and the broker's *inline* policy references the worker/submitter
# ARNs. Because inline policies are separate aws_iam_role_policy resources,
# this is acyclic in the resource graph.

# --- Broker Lambda execution role -------------------------------------------

resource "aws_iam_role" "broker" {
  name = "${var.name_prefix}-broker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# scoped replacement for AWSLambdaBasicExecutionRole (which grants logs on *)
data "aws_caller_identity" "current" {}

locals {
  lambda_log_policy = { for fn in ["broker", "bot"] : fn => jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-${fn}*"
      }
    ]
  }) }
}

resource "aws_iam_role_policy" "broker_logs" {
  name   = "logs"
  role   = aws_iam_role.broker.id
  policy = local.lambda_log_policy["broker"]
}

resource "aws_iam_role_policy" "broker_assume" {
  name = "assume-farm-roles"
  role = aws_iam_role.broker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          aws_iam_role.worker.arn,
          aws_iam_role.submitter.arn,
        ]
      }
    ]
  })
}

# --- Worker role -------------------------------------------------------------

# Trust is pinned to the exact broker *function*, not just its role:
# lambda:SourceFunctionArn is stamped on requests made with Lambda-vended
# credentials, so broker credentials exfiltrated from the Lambda (or any other
# function someone attaches the broker role to) cannot assume these roles.
# Built as a string to keep the resource graph acyclic.
locals {
  broker_function_arn = "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${var.name_prefix}-broker"

  farm_role_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.broker.arn }
        Action    = "sts:AssumeRole"
        Condition = {
          ArnEquals = { "lambda:SourceFunctionArn" = local.broker_function_arn }
        }
      }
    ]
  })
}

resource "aws_iam_role" "worker" {
  name               = "${var.name_prefix}-worker"
  assume_role_policy = local.farm_role_trust
}

# shared between the brokered worker role and the EC2 instance profile.
# Every action maps to a specific code path; keep it that way:
#   sqs receive/delete/changevis   claim_job / record_result / heartbeat
#   sqs send                       expand fan-out (enqueue_jobs)
#   runs get/update                run spec fetch, completion counter, expand flip
#   jobs update                    claim + record (conditional writes)
#   jobs batchwrite                expand fan-out (write_jobs)
#   s3 put runs/*                  log upload
locals {
  worker_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeJobQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:SendMessage",
        ]
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Sid    = "RunState"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
        ]
        Resource = aws_dynamodb_table.runs.arn
      },
      {
        Sid    = "JobState"
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateItem",
          "dynamodb:BatchWriteItem",
        ]
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        Sid      = "UploadResults"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.results.arn}/runs/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "worker" {
  name   = "worker-access"
  role   = aws_iam_role.worker.id
  policy = local.worker_policy
}

# --- Submitter role ----------------------------------------------------------

resource "aws_iam_role" "submitter" {
  name               = "${var.name_prefix}-submitter"
  assume_role_policy = local.farm_role_trust
}

# shared between the submitter role (brokered humans/CLIs) and the bot Lambda's
# execution role. Code paths:
#   runs put/get/update/scan   create_run, status, reported-claim, finished-run scan
#   jobs query                 report aggregation (fan-out itself is the workers' job)
#   sqs send                   the expand message
#   s3 under runs/ only        report upload, log fetch (deployment zips live in
#                              a separate bucket no farm principal can touch)
locals {
  submitter_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageRuns"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Scan",
        ]
        Resource = aws_dynamodb_table.runs.arn
      },
      {
        Sid      = "ReadJobs"
        Effect   = "Allow"
        Action   = "dynamodb:Query"
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        Sid      = "EnqueueExpand"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Sid      = "ListRunObjects"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.results.arn
        Condition = {
          StringLike = { "s3:prefix" = "runs/*" }
        }
      },
      {
        Sid    = "ReadWriteRunObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.results.arn}/runs/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "submitter" {
  name   = "submitter-access"
  role   = aws_iam_role.submitter.id
  policy = local.submitter_policy
}
