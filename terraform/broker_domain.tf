# A stable name for the broker: pkgeval.julialang.org (or whatever
# `broker_domain` says) instead of the machine-generated Lambda Function URL,
# so nothing downstream — the CLI default, ci.yml, worker docs — has to chase
# the URL across redeployments or region moves.
#
# Function URLs do not support custom domains, so a CloudFront distribution
# fronts the URL (caching disabled; it is pure indirection). The julialang.org
# zone is hosted outside AWS (Namecheap), so terraform cannot create the DNS
# records; it emits them as the `broker_dns_records` output instead. First
# bring-up is a two-step dance because ACM needs its validation record *before*
# the distribution can be created:
#
#   1. `tofu apply` — creates the certificate, then sits in "Still creating..."
#      on the validation resource. From another shell:
#          tofu state show 'aws_acm_certificate.broker[0]' | grep resource_record
#      and create that CNAME in the zone. Validation completes within minutes
#      of the record resolving and the apply proceeds on its own.
#   2. `tofu output broker_dns_records` — create the remaining CNAME pointing
#      the domain at the distribution.

locals {
  broker_domain_enabled = var.broker_domain == "" ? 0 : 1

  # the Function URL rendered as a bare hostname ("https://<id>.lambda-url...on.aws/")
  broker_origin_host = trimsuffix(trimprefix(aws_lambda_function_url.broker.function_url, "https://"), "/")
}

resource "aws_acm_certificate" "broker" {
  count    = local.broker_domain_enabled
  provider = aws.us_east_1

  domain_name       = var.broker_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# No validation_record_fqdns: the zone is not in Route 53, so this resource
# only polls the certificate until the manually-created record validates it.
resource "aws_acm_certificate_validation" "broker" {
  count    = local.broker_domain_enabled
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.broker[0].arn

  timeouts {
    # generous: issuance waits on a human creating the DNS record
    create = "12h"
  }
}

resource "aws_cloudfront_distribution" "broker" {
  count = local.broker_domain_enabled

  enabled     = true
  comment     = "${var.name_prefix} broker (${var.broker_domain})"
  aliases     = [var.broker_domain]
  price_class = "PriceClass_100"

  origin {
    origin_id   = "broker-function-url"
    domain_name = local.broker_origin_host

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "broker-function-url"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    # managed policies: CachingDisabled (the broker is an API, not content) and
    # AllViewerExceptHostHeader (a Function URL routes on its *own* Host header,
    # so the viewer's must not be forwarded)
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # referencing the *validation* resource makes creation wait for issuance
    acm_certificate_arn      = aws_acm_certificate_validation.broker[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

output "broker_dns_records" {
  description = "DNS records to create in the broker domain's zone (hosted outside AWS)."
  value = var.broker_domain == "" ? [] : concat(
    [for o in aws_acm_certificate.broker[0].domain_validation_options :
    "${o.resource_record_name} ${o.resource_record_type} ${o.resource_record_value} (ACM validation; needed first)"],
    ["${var.broker_domain}. CNAME ${aws_cloudfront_distribution.broker[0].domain_name}."],
  )
}
