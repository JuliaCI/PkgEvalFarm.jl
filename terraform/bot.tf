# The @pkgeval bot Lambda: invoked on a schedule by EventBridge, each
# invocation polls GitHub notifications for runtests() commands, submits runs,
# and posts reports for finished runs. Only created when a bot token is set.
#
# The zip must be built before applying:
#
#   julia --project=bot bot/build/build.jl

locals {
  bot_enabled = var.enable_bot ? 1 : 0
}

# Like the Buildkite token: the values here are placeholders because a real
# secret in terraform state is exactly what this design avoids. Set them out of
# band and never through terraform:
#
#   aws ssm put-parameter --name /pkgeval/bot-github-token --type SecureString \
#     --value "ghp_..." --overwrite
#   aws ssm put-parameter --name /pkgeval/bot-webhook-secret --type SecureString \
#     --value "$(openssl rand -hex 32)" --overwrite
resource "aws_ssm_parameter" "bot_token" {
  count       = local.bot_enabled
  name        = var.bot_token_parameter
  description = "GitHub token of the @${var.bot_name} bot account"
  type        = "SecureString"
  value       = "placeholder-set-out-of-band"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "bot_webhook_secret" {
  count       = local.bot_enabled
  name        = var.bot_webhook_secret_parameter
  description = "HMAC secret for the @${var.bot_name} GitHub webhook"
  type        = "SecureString"
  value       = "placeholder-set-out-of-band"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_iam_role_policy" "bot_secrets" {
  count = local.bot_enabled
  name  = "read-secrets"
  role  = aws_iam_role.bot[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          aws_ssm_parameter.bot_token[0].arn,
          aws_ssm_parameter.bot_webhook_secret[0].arn,
        ]
      }
    ]
  })
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
resource "aws_iam_role_policy_attachment" "bot" {
  count      = local.bot_enabled
  role       = aws_iam_role.bot[0].name
  policy_arn = aws_iam_policy.submitter.arn
}

resource "aws_s3_object" "bot_zip" {
  count       = local.bot_enabled
  bucket      = aws_s3_bucket.lambda.id
  key         = "bot.zip"
  source      = "${path.module}/../bot/build/bootstrap.zip"
  source_hash = try(filemd5("${path.module}/../bot/build/bootstrap.zip"), null)

  # CI publishes new bundles; don't let a stale local file revert them
  lifecycle {
    # tags_all too: CI's publish replaces the object, which strips S3 object
    # tags; without ignoring them every apply repairs cosmetic tag drift
    # (billing attribution lives on the bucket, not these objects)
    ignore_changes = [source, source_hash, etag, tags, tags_all]
  }
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
  # 1024 is ample: a full-ecosystem (24k-job) report peaks at ~188 MB and its
  # real work is tens of seconds even at this size's fractional vCPU — the
  # historical timeout was the quadratic-hashing stall (see FarmLite.hexdigest),
  # not the workload
  memory_size = 1024
  timeout     = 300

  # the function URL is publicly invokable (webhook auth is HMAC inside); real
  # concurrency needs are minimal (stream: one batch per shard, schedule:
  # hourly, webhooks: human-paced), so a small cap bounds URL-spam cost
  reserved_concurrent_executions = 5

  # CI publishes code updates via lambda:UpdateFunctionCode
  lifecycle {
    ignore_changes = [source_code_hash, s3_key]
  }

  environment {
    variables = {
      # do NOT set JULIA_NUM_GC_THREADS=0 here: current 1.13 builds segfault in
      # gc_queue_thread_local during the first collection when run with zero GC
      # threads (reproduced locally; it kept the report path crashing even
      # after the image write-barrier bug was fixed)
      BOT_TOKEN_PARAM      = var.bot_token_parameter
      WEBHOOK_SECRET_PARAM = var.bot_webhook_secret_parameter
      BOT_NAME             = var.bot_name
      # commands are only executed for authorized authors (the bot's token
      # needs read:org to check); empty team = any org member
      GITHUB_ORG             = var.github_org
      SUBMITTER_TEAM         = var.bot_submitter_team == null ? var.submitter_team : var.bot_submitter_team
      PKGEVAL_QUEUE_URL      = aws_sqs_queue.jobs.url
      PKGEVAL_SLOW_QUEUE_URL = aws_sqs_queue.jobs_slow.url
      PKGEVAL_RUNS_TABLE     = aws_dynamodb_table.runs.name
      PKGEVAL_JOBS_TABLE     = aws_dynamodb_table.jobs.name
      PKGEVAL_BUCKET         = aws_s3_bucket.results.bucket
      # lets the DLQ consumer recognize (and recycle) messages that are only
      # waiting on a pending CI build; empty when build requests are disabled
      PKGEVAL_BUILDS_TABLE = local.build_request_enabled == 1 ? aws_dynamodb_table.builds[0].name : ""
      FARM_REGION          = var.region
    }
  }
}

# --- Trigger 1: GitHub issue_comment webhook (HMAC-verified in the bot) --------

# Always created with the bot: HMAC verification is inside the function, and
# with the secret parameter still on its placeholder every delivery gets a 401,
# so an unconfigured webhook endpoint is inert rather than open.
resource "aws_lambda_function_url" "bot" {
  count              = local.bot_enabled
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

  # only invoke for runs reaching a terminal state; per-job counter updates
  # are filtered out for free at the event-source level. "failed" makes
  # worker-side failures (e.g. a Julia build that CI gave up on) report
  # immediately instead of waiting for the next scheduled poll.
  filter_criteria {
    filter {
      pattern = jsonencode({
        dynamodb = { NewImage = { status = { S = ["done", "failed"] } } }
      })
    }
  }

  depends_on = [aws_iam_role_policy.bot_stream]
}

# The dashboard's progress gauge: per-job counter bumps (status stays "active")
# batched up to a minute become one public runs/<id>/report/progress.json write,
# so live progress costs one farm-side PUT per minute of activity instead of
# per-viewer S3 listings. Second consumer on the stream — DynamoDB supports two
# per shard — so its batching window cannot delay the report path above.
resource "aws_lambda_event_source_mapping" "bot_runs_progress" {
  count             = local.bot_enabled
  event_source_arn  = aws_dynamodb_table.runs.stream_arn
  function_name     = aws_lambda_function.bot[0].arn
  starting_position = "LATEST"
  batch_size        = 10000
  maximum_batching_window_in_seconds = 60

  filter_criteria {
    filter {
      pattern = jsonencode({
        dynamodb = { NewImage = { status = { S = ["active"] } } }
      })
    }
  }

  depends_on = [aws_iam_role_policy.bot_stream]
}

# --- Trigger 2b: the jobs DLQ ---------------------------------------------------
# Messages the queue gave up on flow back into the bot, which records them as
# error results (or fails the run, for expand messages) so runs still complete
# and reports still get posted — the DLQ is part of the completion path, not a
# graveyard needing a human.

resource "aws_iam_role_policy" "bot_dlq" {
  count = local.bot_enabled
  name  = "consume-jobs-dlq"
  role  = aws_iam_role.bot[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.jobs_dlq.arn
      },
      {
        # recording dead jobs as error results
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        # checking whether a dead message is merely waiting on a pending build
        Effect   = "Allow"
        Action   = "dynamodb:GetItem"
        Resource = concat([aws_dynamodb_table.jobs.arn], aws_dynamodb_table.builds[*].arn)
      },
    ]
  })
}

resource "aws_lambda_event_source_mapping" "bot_jobs_dlq" {
  count            = local.bot_enabled
  event_source_arn = aws_sqs_queue.jobs_dlq.arn
  function_name    = aws_lambda_function.bot[0].arn
  batch_size       = 10
  # dead messages are hours old already; a little batching latency is free
  maximum_batching_window_in_seconds = 30

  depends_on = [aws_iam_role_policy.bot_dlq]
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
