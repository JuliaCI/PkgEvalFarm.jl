# Job queue that workers poll for PkgEval jobs, plus a dead-letter queue for
# jobs that repeatedly fail to be processed.

resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${var.name_prefix}-jobs-dlq"
  message_retention_seconds = 14 * 24 * 60 * 60 # 14 days
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${var.name_prefix}-jobs"
  visibility_timeout_seconds = 1800
  message_retention_seconds  = 4 * 24 * 60 * 60 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 4
  })
}
