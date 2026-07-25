# The @nanosoldier2 bot Lambda: invoked on a schedule by EventBridge, each
# invocation polls GitHub notifications for runtests() commands, submits runs,
# and posts reports for finished runs. Only created when a bot token is set.
#
# The zip must be built before applying:
#
#   julia --project=bot bot/build/build.jl

locals {
  bot_enabled = var.github_bot_token == "" ? 0 : 1
}

resource "aws_iam_role" "bot" {
  count = local.bot_enabled
  name  = "${var.name_prefix}-bot"

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

resource "aws_iam_role_policy" "bot_logs" {
  count  = local.bot_enabled
  name   = "logs"
  role   = aws_iam_role.bot[0].id
  policy = local.lambda_log_policy["bot"]
}

# the bot is a submitter; its execution role carries the policy directly, so it
# needs neither the broker nor GitHub team membership
resource "aws_iam_role_policy" "bot" {
  count  = local.bot_enabled
  name   = "submitter-access"
  role   = aws_iam_role.bot[0].id
  policy = local.submitter_policy
}

resource "aws_s3_object" "bot_zip" {
  count       = local.bot_enabled
  bucket      = aws_s3_bucket.lambda.id
  key         = "bot.zip"
  source      = "${path.module}/../bot/build/bootstrap.zip"
  source_hash = try(filemd5("${path.module}/../bot/build/bootstrap.zip"), null)
}

resource "aws_lambda_function" "bot" {
  count         = local.bot_enabled
  function_name = "${var.name_prefix}-bot"
  role          = aws_iam_role.bot[0].arn

  s3_bucket        = aws_s3_object.bot_zip[0].bucket
  s3_key           = aws_s3_object.bot_zip[0].key
  source_code_hash = try(filebase64sha256("${path.module}/../bot/build/bootstrap.zip"), null)

  runtime       = "provided.al2023"
  architectures = ["x86_64"]
  handler       = "bootstrap"
  memory_size   = 1024
  timeout       = 300 # report aggregation pages through every job of a run

  environment {
    variables = {
      NANOSOLDIER2_GITHUB_TOKEN = var.github_bot_token
      GITHUB_WEBHOOK_SECRET     = var.github_webhook_secret
      BOT_NAME                  = var.bot_name
      # commands are only executed for authorized authors (the bot's token
      # needs read:org to check); empty team = any org member
      GITHUB_ORG         = var.github_org
      SUBMITTER_TEAM     = var.bot_submitter_team == null ? var.submitter_team : var.bot_submitter_team
      PKGEVAL_QUEUE_URL  = aws_sqs_queue.jobs.url
      PKGEVAL_RUNS_TABLE = aws_dynamodb_table.runs.name
      PKGEVAL_JOBS_TABLE = aws_dynamodb_table.jobs.name
      PKGEVAL_BUCKET     = aws_s3_bucket.results.bucket
      FARM_REGION        = var.region
    }
  }
}

# --- Trigger 1: GitHub issue_comment webhook (HMAC-verified in the bot) --------

resource "aws_lambda_function_url" "bot" {
  count              = var.github_webhook_secret == "" ? 0 : local.bot_enabled
  function_name      = aws_lambda_function.bot[0].function_name
  authorization_type = "NONE"
}

# --- Trigger 2: runs flipping to "done" via the DynamoDB stream ----------------

resource "aws_iam_role_policy" "bot_stream" {
  count = local.bot_enabled
  name  = "runs-stream-read"
  role  = aws_iam_role.bot[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams",
        ]
        Resource = aws_dynamodb_table.runs.stream_arn
      }
    ]
  })
}

resource "aws_lambda_event_source_mapping" "bot_runs_stream" {
  count             = local.bot_enabled
  event_source_arn  = aws_dynamodb_table.runs.stream_arn
  function_name     = aws_lambda_function.bot[0].arn
  starting_position = "LATEST"
  batch_size        = 10

  # only invoke for runs reaching "done"; per-job counter updates are filtered
  # out for free at the event-source level
  filter_criteria {
    filter {
      pattern = jsonencode({
        dynamodb = { NewImage = { status = { S = ["done"] } } }
      })
    }
  }

  depends_on = [aws_iam_role_policy.bot_stream]
}

# --- Trigger 3: infrequent scheduled poll as a fallback ------------------------

resource "aws_cloudwatch_event_rule" "bot_schedule" {
  count               = local.bot_enabled
  name                = "${var.name_prefix}-bot-schedule"
  schedule_expression = var.bot_schedule
}

resource "aws_cloudwatch_event_target" "bot" {
  count = local.bot_enabled
  rule  = aws_cloudwatch_event_rule.bot_schedule[0].name
  arn   = aws_lambda_function.bot[0].arn
}

resource "aws_lambda_permission" "bot_schedule" {
  count         = local.bot_enabled
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bot[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.bot_schedule[0].arn
}
