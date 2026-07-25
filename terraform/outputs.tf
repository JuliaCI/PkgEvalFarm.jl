output "broker_function_url" {
  description = "Public URL of the broker Lambda. This is all a worker needs to join the farm."
  value       = aws_lambda_function_url.broker.function_url
}

output "queue_url" {
  description = "URL of the PkgEval jobs queue."
  value       = aws_sqs_queue.jobs.url
}

output "runs_table" {
  description = "Name of the DynamoDB runs table."
  value       = aws_dynamodb_table.runs.name
}

output "jobs_table" {
  description = "Name of the DynamoDB jobs table."
  value       = aws_dynamodb_table.jobs.name
}

output "bucket" {
  description = "Name of the S3 results bucket."
  value       = aws_s3_bucket.results.bucket
}

output "worker_role_arn" {
  description = "ARN of the IAM role assumed on behalf of workers."
  value       = aws_iam_role.worker.arn
}

output "submitter_role_arn" {
  description = "ARN of the IAM role assumed on behalf of submitters."
  value       = aws_iam_role.submitter.arn
}

output "region" {
  description = "AWS region the farm is deployed in."
  value       = var.region
}

output "bot_function_name" {
  description = "Name of the bot Lambda (empty when the bot is disabled)."
  value       = length(aws_lambda_function.bot) > 0 ? aws_lambda_function.bot[0].function_name : ""
}

output "bot_webhook_url" {
  description = "URL to register as a GitHub issue_comment webhook (empty when disabled)."
  value       = length(aws_lambda_function_url.bot) > 0 ? aws_lambda_function_url.bot[0].function_url : ""
}
