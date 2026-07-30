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
      },
      # The report page's landing view lists recent runs. Anonymous listing
      # is allowed only with exactly this prefix and delimiter, so the only
      # thing enumerable is the set of top-level run ids — whose reports and
      # logs are public above anyway — never object keys.
      {
        Sid       = "PublicListRunIds"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.results.arn
        Condition = {
          StringEquals = {
            "s3:prefix"    = "runs/"
            "s3:delimiter" = "/"
          }
        }
      },
      # ... and gauges an in-flight run's progress by counting its uploaded
      # logs, so listing below a run's logs/ prefix is anonymous too (the log
      # objects themselves are public above; nothing else becomes visible)
      {
        Sid       = "PublicListRunLogs"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.results.arn
        Condition = {
          StringLike = { "s3:prefix" = "runs/*/logs/*" }
        }
      }
    ] : [],
    [
      # workers may only *create* objects, never overwrite: uploads must carry
      # If-None-Match: * (which S3 rejects with 412 if the key exists), so a
      # rogue job with worker credentials cannot falsify already-recorded logs
      # — or, under compilecache/, already-published sealed artifacts (whose
      # immutability is what makes first-writer-wins publication sound, see
      # docs/sealing.md)
      {
        Sid       = "WorkersCreateOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource = [
          "${aws_s3_bucket.results.arn}/runs/*",
          "${aws_s3_bucket.results.arn}/compilecache/*",
        ]
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

# The interactive report page is served from GitHub Pages and fetches
# report.json plus on-demand log tails (Range requests, which preflight)
# straight from this bucket, so browsers need CORS on the objects that are
# already world-readable under the policy above. Read-only: no methods beyond
# GET/HEAD, and no credentials are involved.
resource "aws_s3_bucket_cors_configuration" "results" {
  count  = var.public_reports ? 1 : 0
  bucket = aws_s3_bucket.results.id

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    # just our report page for now — the objects are public either way, so
    # widening this for other consumers of the reports costs nothing beyond
    # adding their origin here
    allowed_origins = ["https://pkgeval-reports.julialang.org"]
    allowed_headers = ["Range"]
    expose_headers  = ["Content-Range", "Content-Length"]
    max_age_seconds = 3600
  }
}

# The Lambda deployment zips live in their own private bucket that no farm
# principal (worker/submitter/bot) has any grant on, so even a policy
# regression on the results bucket cannot become privilege escalation via
# code overwrite.
resource "aws_s3_bucket" "lambda" {
  bucket = "${var.bucket_name}-lambda"
}

# Worker sysimages live here too, under sysimage/<commit>/. They are code the
# EC2 workers *execute*, so the same reasoning applies as for the Lambda zips:
# a bucket no farm principal can write to. EC2 workers get read access to this
# one prefix (see ec2_workers.tf) using their instance-profile credentials;
# manually enrolled workers are long-lived, so they just precompile once and
# never need it.
resource "aws_s3_bucket_policy" "lambda" {
  bucket = aws_s3_bucket.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Unlike the Lambda zips, which CI republishes in place, a sysimage is
      # named after the commit it was built from and never legitimately changes.
      # Refusing overwrites means a leaked deploy credential cannot swap the
      # code under workers that are already booting from it.
      {
        Sid       = "SysimagesAreCreateOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.lambda.arn}/sysimage/*"
        Condition = {
          StringNotEquals = { "s3:if-none-match" = "*" }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "lambda" {
  bucket = aws_s3_bucket.lambda.id

  rule {
    id     = "expire-sysimages"
    status = "Enabled"

    filter {
      prefix = "sysimage/"
    }

    # one per commit that ever deployed, at ~250MB each; workers only ever want
    # the image for the ref they check out, which is the current master
    expiration {
      days = 30
    }
  }
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

  # Sealed compilecache artifacts are keyed by the exact Julia build: PR-build
  # prefixes are worthless once their run finishes, and even a recurring
  # baseline goes stale as master moves. 30 days comfortably covers baseline
  # reuse across PR runs. (If release-build prefixes should ever persist as a
  # package-server dataset, carve them out via object tags, not by raising
  # this.)
  rule {
    id     = "expire-compilecache"
    status = "Enabled"

    filter {
      prefix = "compilecache/"
    }

    expiration {
      days = 30
    }
  }
}
