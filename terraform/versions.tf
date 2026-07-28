terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# CloudFront only accepts ACM certificates issued in us-east-1, wherever the
# rest of the stack runs — this alias exists solely for the broker-domain cert.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "pkgeval"
      Component = "control-plane"
    }
  }
}

provider "aws" {
  region = var.region

  # Cost allocation: everything defaults to the control plane; the EC2 worker
  # fleet (instances, volumes) overrides Component = "workers" at launch, so
  # the two dominant cost pools separate cleanly in Cost Explorer. Activate
  # Project and Component under Billing -> Cost allocation tags (one-time,
  # console-only; usage is categorized from activation onward).
  default_tags {
    tags = {
      Project   = "pkgeval"
      Component = "control-plane"
    }
  }
}
