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

resource "aws_iam_role_policy_attachment" "broker_logs" {
  role       = aws_iam_role.broker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
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

resource "aws_iam_role" "worker" {
  name = "${var.name_prefix}-worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.broker.arn }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# shared between the brokered worker role and the test-instance profile
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
          "sqs:GetQueueAttributes",
          # workers fan out job messages when expanding a run's package list
          "sqs:SendMessage",
        ]
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Sid    = "UpdateJobAndRunState"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
        ]
        Resource = [
          aws_dynamodb_table.jobs.arn,
          aws_dynamodb_table.runs.arn,
        ]
      },
      {
        Sid      = "ExpandRunJobs"
        Effect   = "Allow"
        Action   = "dynamodb:BatchWriteItem"
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
  name = "${var.name_prefix}-submitter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.broker.arn }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# shared between the submitter role (brokered humans/CLIs) and the bot Lambda's
# execution role
locals {
  submitter_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageRunsAndJobs"
        Effect = "Allow"
        # job-item fan-out (BatchWriteItem) is the workers' job, even for explicit
        # package lists, so submitters get by with single-item operations
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan",
        ]
        Resource = [
          aws_dynamodb_table.runs.arn,
          aws_dynamodb_table.jobs.arn,
        ]
      },
      {
        Sid      = "EnqueueJobs"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.jobs.arn
      },
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.results.arn
      },
      {
        Sid    = "ReadWriteObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.results.arn}/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "submitter" {
  name   = "submitter-access"
  role   = aws_iam_role.submitter.id
  policy = local.submitter_policy
}
