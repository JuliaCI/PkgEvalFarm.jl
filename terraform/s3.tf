# Results bucket. Workers upload logs and artifacts under runs/<run_id>/...;
# reports are published under runs/<run_id>/report/. When public_reports is
# enabled, reports and logs are world-readable via a bucket policy.

resource "aws_s3_bucket" "results" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket = aws_s3_bucket.results.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = !var.public_reports
  restrict_public_buckets = !var.public_reports
}

locals {
  # role ARNs that hold worker credentials (brokered + EC2 instance profile)
  worker_role_arns = concat([aws_iam_role.worker.arn],
  aws_iam_role.ec2_worker[*].arn)

  results_policy_statements = concat(
    var.public_reports ? [
      {
        Sid       = "PublicReadReportsAndLogs"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource = [
          "${aws_s3_bucket.results.arn}/runs/*/report/*",
          "${aws_s3_bucket.results.arn}/runs/*/logs/*",
        ]
      }
    ] : [],
    [
      # workers may only *create* objects, never overwrite: uploads must carry
      # If-None-Match: * (which S3 rejects with 412 if the key exists), so a
      # rogue job with worker credentials cannot falsify already-recorded logs
      {
        Sid       = "WorkersCreateOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.results.arn}/runs/*"
        Condition = {
          StringNotEquals = { "s3:if-none-match" = "*" }
          ArnLike         = { "aws:PrincipalArn" = local.worker_role_arns }
        }
      }
    ]
  )
}

resource "aws_s3_bucket_policy" "results" {
  bucket = aws_s3_bucket.results.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.results_policy_statements
  })

  depends_on = [aws_s3_bucket_public_access_block.results]
}

# The Lambda deployment zips live in their own private bucket that no farm
# principal (worker/submitter/bot) has any grant on, so even a policy
# regression on the results bucket cannot become privilege escalation via
# code overwrite.
resource "aws_s3_bucket" "lambda" {
  bucket = "${var.bucket_name}-lambda"
}

resource "aws_s3_bucket_public_access_block" "lambda" {
  bucket = aws_s3_bucket.lambda.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "expire-runs"
    status = "Enabled"

    filter {
      prefix = "runs/"
    }

    expiration {
      days = 180
    }
  }
}
