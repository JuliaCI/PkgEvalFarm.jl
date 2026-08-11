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

# Seal queue: compilecache seal jobs (docs/sealing.md), polled by workers
# before everything else — sealing must run ahead of the test jobs it warms,
# and priority between queues is the only ordering SQS honors. Messages are
# enqueued as their dependency counters hit zero (topological waves).
# Derivations are the leaves of the sealing dataflow: they fetch with nohold
# probes, so they never wait on anything — always-runnable, pure CPU work.
# They get their own queue, claimed with priority above every other, because
# sharing the seal queue inverted the dependency order: seal jobs held on
# derivations buried BEHIND them, and donated/gated slots could only claim
# more of the same waiting work (head-of-line blocking; fleet at 30% CPU
# with 3.5K messages queued, 2026-08-11).
resource "aws_sqs_queue" "jobs_deriv" {
  name                       = "${var.name_prefix}-jobs-deriv"
  visibility_timeout_seconds = 1800
  message_retention_seconds  = 4 * 24 * 60 * 60 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 6
  })
}

resource "aws_sqs_queue" "jobs_seal" {
  name                       = "${var.name_prefix}-jobs-seal"
  visibility_timeout_seconds = 1800
  message_retention_seconds  = 4 * 24 * 60 * 60 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    # seal jobs never wait on CI builds (their run is active, so the build is
    # staged) and give up on themselves after 3 attempts; this is pure backstop
    maxReceiveCount = 6
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
