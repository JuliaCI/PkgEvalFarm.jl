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

output "ec2_worker_asg" {
  description = "Name of the EC2 worker auto-scaling group (empty when disabled)."
  value       = length(aws_autoscaling_group.ec2_worker) > 0 ? aws_autoscaling_group.ec2_worker[0].name : ""
}

output "deploy_role_arn" {
  description = "Role for GitHub Actions to assume via OIDC (set as the AWS_DEPLOY_ROLE repo variable)."
  value       = aws_iam_role.deploy.arn
}

output "lambda_bucket" {
  description = "Private bucket holding the Lambda deployment bundles."
  value       = aws_s3_bucket.lambda.bucket
}

output "debug_role_arn" {
  description = "Read-only debug role (empty when debug_role_principals is null)."
  value       = length(aws_iam_role.debug) > 0 ? aws_iam_role.debug[0].arn : ""
}

output "build_request_function" {
  description = "Name of the build-request Lambda workers invoke (empty when disabled)."
  value       = length(aws_lambda_function.build_request) > 0 ? aws_lambda_function.build_request[0].function_name : ""
}

output "slow_queue_url" {
  description = "URL of the long-jobs queue (workers drain it before the main queue)."
  value       = aws_sqs_queue.jobs_slow.url
}

output "seal_queue_url" {
  description = "URL of the compilecache seal queue (docs/sealing.md; workers poll it first)."
  value       = aws_sqs_queue.jobs_seal.url
}

output "dashboard_identity_pool" {
  description = "Cognito identity pool the dashboard uses for anonymous runs-table reads (bake into site/index.html; empty when reports are private)."
  value       = length(aws_cognito_identity_pool.dashboard) > 0 ? aws_cognito_identity_pool.dashboard[0].id : ""
}
