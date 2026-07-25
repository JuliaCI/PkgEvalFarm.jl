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

resource "aws_iam_role_policy_attachment" "bot_logs" {
  count      = local.bot_enabled
  role       = aws_iam_role.bot[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
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
  bucket      = aws_s3_bucket.results.id
  key         = "lambda/bot.zip"
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
      BOT_NAME                  = var.bot_name
      PKGEVAL_QUEUE_URL         = aws_sqs_queue.jobs.url
      PKGEVAL_RUNS_TABLE        = aws_dynamodb_table.runs.name
      PKGEVAL_JOBS_TABLE        = aws_dynamodb_table.jobs.name
      PKGEVAL_BUCKET            = aws_s3_bucket.results.bucket
      FARM_REGION               = var.region
    }
  }
}

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
