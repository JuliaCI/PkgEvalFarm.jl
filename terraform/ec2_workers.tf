# Optional EC2 worker capacity (testing and burst), as a spot-first auto-scaling
# group. Off by default; scale with:
#
#   tofu apply -var ec2_worker_count=4
#   tofu apply -var ec2_worker_count=0
#
# Interrupted spot instances are replaced by the ASG automatically; that is safe
# by construction, since a killed worker's jobs stop being heartbeated and are
# redelivered by SQS (with the package cache disabled on retry).
#
# Being inside AWS, these workers skip the GitHub-device-flow enrollment: an
# instance profile carries the same worker policy the broker would vend, and the
# worker CLI's env-bypass mode uses it via the instance metadata service. Debug
# access is via SSM Session Manager (no ingress at all).

locals {
  ec2_workers = var.ec2_worker_count > 0 ? 1 : 0
}

resource "aws_iam_role" "ec2_worker" {
  count = local.ec2_workers
  name  = "${var.name_prefix}-ec2-worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "ec2_worker" {
  count  = local.ec2_workers
  name   = "worker-access"
  role   = aws_iam_role.ec2_worker[0].id
  policy = local.worker_policy
}

resource "aws_iam_role_policy_attachment" "ec2_worker_ssm" {
  count      = local.ec2_workers
  role       = aws_iam_role.ec2_worker[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_worker" {
  count = local.ec2_workers
  name  = "${var.name_prefix}-ec2-worker"
  role  = aws_iam_role.ec2_worker[0].name
}

data "aws_vpc" "default" {
  count   = local.ec2_workers
  default = true
}

data "aws_subnets" "default" {
  count = local.ec2_workers
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

resource "aws_security_group" "ec2_worker" {
  count       = local.ec2_workers
  name        = "${var.name_prefix}-ec2-worker"
  description = "PkgEval EC2 workers: egress only"
  vpc_id      = data.aws_vpc.default[0].id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu" {
  count       = local.ec2_workers
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_launch_template" "ec2_worker" {
  count         = local.ec2_workers
  name          = "${var.name_prefix}-ec2-worker"
  image_id      = data.aws_ami.ubuntu[0].id
  instance_type = var.ec2_worker_instance_types[0]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_worker[0].name
  }
  vpc_security_group_ids = [aws_security_group.ec2_worker[0].id]

  metadata_options {
    http_tokens = "required" # IMDSv2 (AWS.jl supports it)
    # PkgEval sandboxes reach IMDS through the worker's network namespace hops
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.ec2_worker_disk_gb
      volume_type = "gp3"
    }
  }

  user_data = base64encode(templatefile("${path.module}/ec2_worker_userdata.sh.tpl", {
    region        = var.region
    queue_url     = aws_sqs_queue.jobs.url
    runs_table    = aws_dynamodb_table.runs.name
    jobs_table    = aws_dynamodb_table.jobs.name
    bucket        = aws_s3_bucket.results.bucket
    farm_repo     = var.ec2_worker_farm_repo
    farm_ref      = var.ec2_worker_farm_ref
    julia_channel = var.ec2_worker_julia_channel
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-ec2-worker"
    }
  }
}

resource "aws_autoscaling_group" "ec2_worker" {
  count               = local.ec2_workers
  name                = "${var.name_prefix}-ec2-worker"
  min_size            = 0
  max_size            = var.ec2_worker_max
  desired_capacity    = var.ec2_worker_count
  vpc_zone_identifier = data.aws_subnets.default[0].ids

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = var.ec2_worker_on_demand_percent
      spot_allocation_strategy                 = "price-capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.ec2_worker[0].id
        version            = "$Latest"
      }
      dynamic "override" {
        for_each = var.ec2_worker_instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }
}
