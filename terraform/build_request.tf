# Build-request broker: lets workers ask Julia CI to build a commit that has no
# staged artifact, without ever holding the credential that does it.
#
# Workers run arbitrary package code, so the Buildkite token lives in an SSM
# parameter only this Lambda may read. Workers reach the Lambda through a
# Function URL with AWS_IAM authorization — SigV4 with the credentials they
# already have, so no new secret is distributed and access is revoked by
# removing an IAM grant.
#
# The token should belong to a Buildkite *machine user* whose team membership
# grants access to the build-request pipeline and nothing else: `write_builds`
# is an organization-wide scope name, but the user's pipeline permissions bound
# what it can actually reach.
#
# Created only when buildkite_pipeline is set.

locals {
  build_request_enabled = var.buildkite_pipeline == "" ? 0 : 1
}

resource "aws_dynamodb_table" "builds" {
  count        = local.build_request_enabled
  name         = "${var.name_prefix}-builds"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "build_key" # "<sha>/<variant>"

  attribute {
    name = "build_key"
    type = "S"
  }
}

# The value is deliberately a placeholder: a real token in terraform state is
# exactly what this design avoids. Set it out of band and never through
# terraform:
#
#   aws ssm put-parameter --name /pkgeval/buildkite-token --type SecureString \
#     --value "bkua_..." --overwrite
resource "aws_ssm_parameter" "buildkite_token" {
  count       = local.build_request_enabled
  name        = var.buildkite_token_parameter
  description = "Buildkite API token for the PkgEval build-request pipeline (machine user)"
  type        = "SecureString"
  value       = "placeholder-set-out-of-band"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_iam_role" "build_request" {
  count = local.build_request_enabled
  name  = "${var.name_prefix}-build-request"

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

resource "aws_iam_role_policy" "build_request" {
  count = local.build_request_enabled
  name  = "request-builds"
  role  = aws_iam_role.build_request[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadBuildkiteToken"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.buildkite_token[0].arn
      },
      {
        Sid    = "DeduplicateRequests"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem",
          # a claim whose Buildkite trigger failed is released (deleted) so the
          # next asker retries instead of no-oping on a poisoned record
        "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.builds[0].arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-build-request*"
      },
    ]
  })
}

resource "aws_s3_object" "build_request_zip" {
  count       = local.build_request_enabled
  bucket      = aws_s3_bucket.lambda.id
  key         = "build-request.zip"
  source      = "${path.module}/../buildreq/build/bootstrap.zip"
  source_hash = try(filemd5("${path.module}/../buildreq/build/bootstrap.zip"), null)

  lifecycle {
    ignore_changes = [source, source_hash, etag]
  }
}

resource "aws_lambda_function" "build_request" {
  count         = local.build_request_enabled
  function_name = "${var.name_prefix}-build-request"
  role          = aws_iam_role.build_request[0].arn

  s3_bucket        = aws_s3_object.build_request_zip[0].bucket
  s3_key           = aws_s3_object.build_request_zip[0].key
  source_code_hash = try(filebase64sha256("${path.module}/../buildreq/build/bootstrap.zip"), null)

  runtime       = "provided.al2023"
  architectures = ["x86_64"]
  handler       = "bootstrap"
  memory_size   = 512
  timeout       = 30

  # one build request at a time is plenty; also bounds any runaway worker loop
  reserved_concurrent_executions = 5

  lifecycle {
    ignore_changes = [source_code_hash, s3_key]
  }

  environment {
    variables = {
      BUILDKITE_ORG         = var.buildkite_org
      BUILDKITE_PIPELINE    = var.buildkite_pipeline
      BUILDKITE_TOKEN_PARAM = var.buildkite_token_parameter
      PKGEVAL_BUILDS_TABLE  = aws_dynamodb_table.builds[0].name
      PKGEVAL_QUEUE_URL     = aws_sqs_queue.jobs.url
      PKGEVAL_RUNS_TABLE    = aws_dynamodb_table.runs.name
      PKGEVAL_JOBS_TABLE    = aws_dynamodb_table.jobs.name
      PKGEVAL_BUCKET        = aws_s3_bucket.results.bucket
      FARM_REGION           = var.region
    }
  }
}

# Workers call the broker through the plain Invoke API. (The original design
# used a SigV4-signed Function URL, but the URL auth layer consistently 403'd
# assumed-role sessions despite valid identity- and resource-policy allows —
# the same signed requests from an IAM user worked. Abandoned as
# undiagnosable; the Invoke API is the best-trodden auth path there is.)
resource "aws_iam_policy" "request_builds" {
  count       = local.build_request_enabled
  name        = "${var.name_prefix}-request-builds"
  description = "Invoke the build-request Lambda (workers)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.build_request[0].arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_request_builds" {
  count      = local.build_request_enabled
  role       = aws_iam_role.worker.name
  policy_arn = aws_iam_policy.request_builds[0].arn
}

resource "aws_iam_role_policy_attachment" "ec2_worker_request_builds" {
  count      = local.build_request_enabled * local.ec2_workers
  role       = aws_iam_role.ec2_worker[0].name
  policy_arn = aws_iam_policy.request_builds[0].arn
}
