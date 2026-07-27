terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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
