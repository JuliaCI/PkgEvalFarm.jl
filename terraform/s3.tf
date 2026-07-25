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

resource "aws_s3_bucket_policy" "public_reports" {
  count = var.public_reports ? 1 : 0

  bucket = aws_s3_bucket.results.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.results]
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
