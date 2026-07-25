# DynamoDB tables tracking PkgEval runs and their individual jobs.

resource "aws_dynamodb_table" "runs" {
  name         = "${var.name_prefix}-runs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "run_id"

  attribute {
    name = "run_id"
    type = "S"
  }

  # the bot Lambda subscribes to this stream (filtered to runs flipping to
  # "done") to post reports without polling
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"
}

resource "aws_dynamodb_table" "jobs" {
  name         = "${var.name_prefix}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "run_id"
  range_key    = "job_key"

  attribute {
    name = "run_id"
    type = "S"
  }

  attribute {
    name = "job_key"
    type = "S"
  }
}
