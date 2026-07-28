# The broker Lambda: authenticates users via the GitHub device flow, checks
# team membership, and vends temporary AWS credentials (worker or submitter).
# The zip must be built before applying:
#
#   julia --project=broker broker/build/build.jl

# the juliac bundles exceed Lambda's 50 MB direct-upload limit, so the zips are
# staged through the dedicated (strictly private) lambda bucket
resource "aws_s3_object" "broker_zip" {
  bucket = aws_s3_bucket.lambda.id
  key    = "broker.zip"
  source = "${path.module}/../broker/build/bootstrap.zip"
  # try() so that `tofu validate` succeeds before the zip has been built; on a
  # real plan/apply the zip must exist (see README) and the hash is computed.
  source_hash = try(filemd5("${path.module}/../broker/build/bootstrap.zip"), null)

  # CI publishes new bundles; don't let a stale local file revert them
  lifecycle {
    ignore_changes = [source, source_hash, etag]
  }
}

resource "aws_lambda_function" "broker" {
  function_name = "${var.name_prefix}-broker"
  role          = aws_iam_role.broker.arn

  s3_bucket        = aws_s3_object.broker_zip.bucket
  s3_key           = aws_s3_object.broker_zip.key
  source_code_hash = try(filebase64sha256("${path.module}/../broker/build/bootstrap.zip"), null)

  runtime       = "provided.al2023"
  architectures = ["x86_64"]
  handler       = "bootstrap"
  memory_size   = 512
  timeout       = 30

  # the function URL is publicly invokable (auth happens against GitHub inside);
  # a concurrency cap bounds the cost/abuse blast radius of URL spam
  reserved_concurrent_executions = 10

  # CI publishes code updates via lambda:UpdateFunctionCode
  lifecycle {
    ignore_changes = [source_code_hash, s3_key]
  }

  environment {
    variables = {
      GITHUB_ORG             = var.github_org
      WORKER_TEAM            = var.worker_team
      SUBMITTER_TEAM         = var.submitter_team
      GITHUB_CLIENT_ID       = var.github_client_id
      WORKER_ROLE_ARN        = aws_iam_role.worker.arn
      SUBMITTER_ROLE_ARN     = aws_iam_role.submitter.arn
      CRED_DURATION          = tostring(var.cred_duration_seconds)
      PKGEVAL_QUEUE_URL      = aws_sqs_queue.jobs.url
      PKGEVAL_SLOW_QUEUE_URL = aws_sqs_queue.jobs_slow.url
      # vended to workers so they can ask CI for missing Julia builds
      PKGEVAL_BUILD_REQUEST_FUNCTION = local.build_request_enabled == 1 ? aws_lambda_function.build_request[0].function_name : ""
      PKGEVAL_RUNS_TABLE             = aws_dynamodb_table.runs.name
      PKGEVAL_JOBS_TABLE             = aws_dynamodb_table.jobs.name
      PKGEVAL_BUCKET                 = aws_s3_bucket.results.bucket
      FARM_REGION                    = var.region
    }
  }
}

resource "aws_lambda_function_url" "broker" {
  function_name      = aws_lambda_function.broker.function_name
  authorization_type = "NONE"
}
