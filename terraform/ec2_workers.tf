# Optional EC2 worker capacity (testing and burst), as a spot-first auto-scaling
# group that scales itself off the job queue. Enable by setting the capacity
# ceiling (`-var ec2_worker_max=16`); scaling within [ec2_worker_min, max] is
# then automatic:
#
#   - scale-out is proportional to the queue backlog per in-service instance
#     (target tracking, scale-out ONLY — draining backlog never churns busy
#     workers) and cannot exceed ec2_worker_max. A long instance-warmup stops
#     the ASG from over-ordering while instances are still booting.
#   - a "kickstart" policy brings up the first instance when the queue becomes
#     non-empty (from zero instances the backlog ratio cannot breach the
#     target). That first worker also expands the run, so large fan-outs only
#     attract capacity once the real job count is on the queue.
#   - capacity drops to ec2_worker_min only once visible + in-flight messages
#     have been zero for ec2_worker_idle_minutes (in-flight counts running
#     jobs, so the long tail is never cut short).
#
# Set ec2_worker_min = ec2_worker_max to pin fixed capacity instead.
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
  ec2_workers = var.ec2_worker_max > 0 ? 1 : 0
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

resource "aws_iam_role_policy_attachment" "ec2_worker" {
  count      = local.ec2_workers
  role       = aws_iam_role.ec2_worker[0].name
  policy_arn = aws_iam_policy.worker.arn
}

resource "aws_iam_role_policy_attachment" "ec2_worker_ssm" {
  count      = local.ec2_workers
  role       = aws_iam_role.ec2_worker[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read-only, and only the sysimage prefix: an EC2 worker downloads the image
# built from the revision it checks out (cloud-init falls back to precompiling
# if it is missing). Deliberately not granted to the brokered worker role —
# those machines are long-lived, so paying precompilation once is nothing, and
# the Lambda bucket stays entirely unreachable from off-farm credentials.
resource "aws_iam_role_policy" "ec2_worker_sysimage" {
  count = local.ec2_workers
  name  = "read-sysimage"
  role  = aws_iam_role.ec2_worker[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.lambda.arn}/sysimage/*"
      }
    ]
  })
}

# Fleet-drain coordination (src/worker.jl): the worker manages its *own*
# scale-in protection and reads fleet membership + queue depth. Describe* has
# no resource-level scoping in the AutoScaling API; SetInstanceProtection is
# pinned to this one ASG (by its well-known name, to keep the graph acyclic).
resource "aws_iam_role_policy" "ec2_worker_fleet" {
  count = local.ec2_workers
  name  = "fleet-drain"
  role  = aws_iam_role.ec2_worker[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "autoscaling:SetInstanceProtection"
        Resource = "arn:aws:autoscaling:${var.region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.name_prefix}-ec2-worker"
      },
      {
        Effect   = "Allow"
        Action   = "autoscaling:DescribeAutoScalingGroups"
        Resource = "*"
      },
      {
        # the CI-green sha a new fleet generation starts from
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/pkgeval/worker-ref"
      },
      {
        Effect   = "Allow"
        Action   = "sqs:GetQueueAttributes"
        Resource = [aws_sqs_queue.jobs.arn, aws_sqs_queue.jobs_slow.arn]
      },
    ]
  })
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

data "aws_subnet" "default" {
  for_each = local.ec2_workers == 0 ? toset([]) : toset(data.aws_subnets.default[0].ids)
  id       = each.value
}

# Legacy zones (us-east-1e, for one) do not offer modern instance types, and the
# default VPC has a subnet in every zone. Handing those subnets to the ASG makes
# it burn launch attempts on InvalidFleetConfiguration before retrying elsewhere,
# which delays scale-out exactly when capacity is wanted.
data "aws_ec2_instance_type_offerings" "worker" {
  count         = local.ec2_workers
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = var.ec2_worker_instance_types
  }
}

locals {
  worker_subnets = local.ec2_workers == 0 ? [] : [
    for s in data.aws_subnet.default : s.id
    if contains(data.aws_ec2_instance_type_offerings.worker[0].locations, s.availability_zone)
  ]
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
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
    # PkgEval sandboxes share the host network namespace, so cloud-init
    # additionally firewalls IMDS to root and hands the worker credentials
    # through a bearer-gated localhost proxy — see ec2_worker_userdata.sh.tpl.
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.ec2_worker_disk_gb
      volume_type = "gp3"
    }
  }

  user_data = base64encode(templatefile("${path.module}/ec2_worker_userdata.sh.tpl", {
    region         = var.region
    queue_url      = aws_sqs_queue.jobs.url
    slow_queue_url = aws_sqs_queue.jobs_slow.url
    # by name, not reference: the launch template cannot depend on the ASG
    asg_name          = "${var.name_prefix}-ec2-worker"
    build_request_function = local.build_request_enabled == 1 ? aws_lambda_function.build_request[0].function_name : ""
    runs_table    = aws_dynamodb_table.runs.name
    jobs_table    = aws_dynamodb_table.jobs.name
    bucket        = aws_s3_bucket.results.bucket
    farm_repo     = var.ec2_worker_farm_repo
    farm_ref      = var.ec2_worker_farm_ref
    julia_channel = var.ec2_worker_julia_channel
    # private; workers read it with their instance profile (see the
    # read-sysimage policy above)
    sysimage_bucket = aws_s3_bucket.lambda.bucket
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = "${var.name_prefix}-ec2-worker"
      Project   = "pkgeval"
      Component = "workers"
    }
  }
  # the worker disks are a real line item at ec2_worker_disk_gb per instance
  tag_specifications {
    resource_type = "volume"
    tags = {
      Name      = "${var.name_prefix}-ec2-worker"
      Project   = "pkgeval"
      Component = "workers"
    }
  }
}

resource "aws_autoscaling_group" "ec2_worker" {
  count               = local.ec2_workers
  name                = "${var.name_prefix}-ec2-worker"

  # belt-and-braces with the launch template's tag_specifications: ASG-launched
  # capacity (including spot replacements) always carries the cost tags
  tag {
    key                 = "Project"
    value               = "pkgeval"
    propagate_at_launch = true
  }
  tag {
    key                 = "Component"
    value               = "workers"
    propagate_at_launch = true
  }
  min_size            = var.ec2_worker_min
  max_size            = var.ec2_worker_max
  desired_capacity    = var.ec2_worker_min
  vpc_zone_identifier = local.worker_subnets

  # instances need to install Julia and warm caches before they consume at full
  # rate; a long warmup prevents the scaler from over-ordering in the meantime
  default_instance_warmup = 900

  # the scale-out policy divides queue backlog by this metric
  enabled_metrics = ["GroupInServiceInstances"]

  # Gradual scale-down: instances launch protected from scale-in and the worker
  # removes its own protection once it has drained (and re-protects when it
  # claims again) — see fleet drain in src/worker.jl. The idle policy can then
  # fire on an *empty queue* alone: it only ever reaps drained instances, so
  # stragglers running elsewhere no longer pin the whole fleet.
  protect_from_scale_in = true

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

  lifecycle {
    # desired_capacity is owned by the scaling policies after creation
    ignore_changes = [desired_capacity]
  }
}


## scaling policies

# 1. proportional scale-out: keep (visible backlog / in-service instances) at the
#    target; never scales in (that's policy 3's job, and only when fully idle)
resource "aws_autoscaling_policy" "ec2_worker_backlog" {
  count                  = local.ec2_workers
  name                   = "backlog-per-instance"
  autoscaling_group_name = aws_autoscaling_group.ec2_worker[0].name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value     = var.ec2_worker_backlog_target
    disable_scale_in = true

    customized_metric_specification {
      metrics {
        id          = "backlog"
        return_data = false
        metric_stat {
          stat = "Average"
          metric {
            namespace   = "AWS/SQS"
            metric_name = "ApproximateNumberOfMessagesVisible"
            dimensions {
              name  = "QueueName"
              value = aws_sqs_queue.jobs.name
            }
          }
        }
      }
      metrics {
        id          = "backlog_slow"
        return_data = false
        metric_stat {
          stat = "Average"
          metric {
            namespace   = "AWS/SQS"
            metric_name = "ApproximateNumberOfMessagesVisible"
            dimensions {
              name  = "QueueName"
              value = aws_sqs_queue.jobs_slow.name
            }
          }
        }
      }
      metrics {
        id          = "instances"
        return_data = false
        metric_stat {
          stat = "Average"
          metric {
            namespace   = "AWS/AutoScaling"
            metric_name = "GroupInServiceInstances"
            dimensions {
              name  = "AutoScalingGroupName"
              value = aws_autoscaling_group.ec2_worker[0].name
            }
          }
        }
      }
      metrics {
        id = "per_instance"
        # CloudWatch metric math has no element-wise MAX against a constant, and
        # dividing by a zero instance count yields no data — guard with IF.
        # (Scaling up from zero is the kickstart policy's job, below.)
        expression  = "IF(instances > 0, (backlog + backlog_slow) / instances, backlog + backlog_slow)"
        label       = "queue backlog per in-service worker"
        return_data = true
      }
    }
  }
}

# 2. kickstart: from zero instances the ratio above cannot breach the target, so
#    bring up exactly one worker as soon as the queue is non-empty
resource "aws_cloudwatch_metric_alarm" "ec2_worker_kickstart" {
  count               = local.ec2_workers
  alarm_name          = "${var.name_prefix}-ec2-worker-kickstart"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "Job queue is non-empty but no EC2 workers are running"
  alarm_actions       = [aws_autoscaling_policy.ec2_worker_kickstart[0].arn]

  metric_query {
    id          = "backlog"
    return_data = false
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      period      = 60
      stat        = "Average"
      dimensions  = { QueueName = aws_sqs_queue.jobs.name }
    }
  }
  metric_query {
    id          = "backlog_slow"
    return_data = false
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      period      = 60
      stat        = "Average"
      dimensions  = { QueueName = aws_sqs_queue.jobs_slow.name }
    }
  }
  metric_query {
    id          = "instances"
    return_data = false
    metric {
      namespace   = "AWS/AutoScaling"
      metric_name = "GroupInServiceInstances"
      period      = 60
      stat        = "Average"
      dimensions  = { AutoScalingGroupName = aws_autoscaling_group.ec2_worker[0].name }
    }
  }
  metric_query {
    id = "needs_kickstart"
    # metric math has no AND: comparisons yield 0/1 series, so multiply them.
    # FILL covers the gap before the ASG has published any instance metric.
    expression  = "(backlog + backlog_slow > 0) * (FILL(instances, 0) < 1)"
    label       = "queue waiting with no workers"
    return_data = true
  }
}

resource "aws_autoscaling_policy" "ec2_worker_kickstart" {
  count                  = local.ec2_workers
  name                   = "kickstart"
  autoscaling_group_name = aws_autoscaling_group.ec2_worker[0].name
  policy_type            = "StepScaling"
  adjustment_type        = "ExactCapacity"

  step_adjustment {
    metric_interval_lower_bound = 0
    scaling_adjustment          = 1
  }
}

# 3. scale to min once the queue has been fully idle (nothing visible, nothing
#    in flight) for a while
resource "aws_cloudwatch_metric_alarm" "ec2_worker_idle" {
  count               = local.ec2_workers
  alarm_name          = "${var.name_prefix}-ec2-worker-idle"
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0
  evaluation_periods  = max(1, ceil(var.ec2_worker_idle_minutes / 5))
  treat_missing_data  = "breaching"
  # visible only, deliberately: in-flight jobs are represented by their
  # instances' scale-in protection, so drained machines are reclaimed while
  # stragglers finish elsewhere instead of the fleet waiting on the last job
  alarm_description   = "Job queues empty (in-flight work is covered by scale-in protection)"
  alarm_actions       = [aws_autoscaling_policy.ec2_worker_idle[0].arn]

  metric_query {
    id          = "visible"
    return_data = false
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      period      = 300
      stat        = "Maximum"
      dimensions  = { QueueName = aws_sqs_queue.jobs.name }
    }
  }
  metric_query {
    id          = "visible_slow"
    return_data = false
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      period      = 300
      stat        = "Maximum"
      dimensions  = { QueueName = aws_sqs_queue.jobs_slow.name }
    }
  }
  metric_query {
    id          = "total"
    expression  = "visible + visible_slow"
    label       = "total visible jobs across both queues"
    return_data = true
  }
}

resource "aws_autoscaling_policy" "ec2_worker_idle" {
  count                  = local.ec2_workers
  name                   = "scale-to-min-when-idle"
  autoscaling_group_name = aws_autoscaling_group.ec2_worker[0].name
  policy_type            = "StepScaling"
  adjustment_type        = "ExactCapacity"

  step_adjustment {
    metric_interval_upper_bound = 0
    scaling_adjustment          = var.ec2_worker_min
  }
}
