# Job queue that workers poll for PkgEval jobs, plus a dead-letter queue for
# jobs that repeatedly fail to be processed.

resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${var.name_prefix}-jobs-dlq"
  message_retention_seconds = 14 * 24 * 60 * 60 # 14 days
  # the bot consumes this queue via an event-source mapping, and Lambda
  # requires the source queue's visibility to cover the function timeout
  visibility_timeout_seconds = 1800
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${var.name_prefix}-jobs"
  visibility_timeout_seconds = 1800
  message_retention_seconds  = 4 * 24 * 60 * 60 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    # must cover a job's worth of worker crashes AND a message cycling every
    # BUILD_RETRY_DELAY (10 min) while CI builds a requested Julia. Build
    # *failures* are detected by the build-request Lambda polling Buildkite
    # (and surfaced as run/job failures within ~one retry), so the DLQ is no
    # longer the failure detector — this budget only needs to outlast slow
    # successful builds: 18 x 10 min = 3 h, matching the Lambda's build-age
    # backstop. Package jobs give up on themselves after 3 attempts anyway.
    maxReceiveCount = 18
  })
}

# Long-jobs queue: at expansion, jobs above a run-mix-derived duration cutoff
# land here and workers drain it before the main queue. Priority *between*
# queues is the only ordering SQS honors — standard-queue delivery under
# backlog is nowhere near FIFO (observed to be roughly recency-biased), so
# enqueue order is meaningless. Expand messages ride this queue too.
resource "aws_sqs_queue" "jobs_slow" {
  name                       = "${var.name_prefix}-jobs-slow"
  visibility_timeout_seconds = 1800
  message_retention_seconds  = 4 * 24 * 60 * 60 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 18 # see above; expand messages ride this queue
  })
}
