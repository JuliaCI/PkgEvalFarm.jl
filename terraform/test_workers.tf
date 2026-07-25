# Optional EC2 test workers that enroll themselves on boot. Off by default;
# spin up/down with:
#
#   tofu apply -var test_worker_count=2
#   tofu apply -var test_worker_count=0
#
# Being inside AWS, they skip the GitHub-device-flow enrollment entirely: an
# instance profile carries the same worker policy the broker would vend, and
# the worker CLI's env-bypass mode uses it via the instance metadata service.
# Debug access is via SSM Session Manager (`aws ssm start-session`), so the
# security group needs no ingress at all.

resource "aws_iam_role" "test_worker" {
  count = var.test_worker_count > 0 ? 1 : 0
  name  = "${var.name_prefix}-test-worker"

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

resource "aws_iam_role_policy" "test_worker" {
  count  = var.test_worker_count > 0 ? 1 : 0
  name   = "worker-access"
  role   = aws_iam_role.test_worker[0].id
  policy = local.worker_policy
}

resource "aws_iam_role_policy_attachment" "test_worker_ssm" {
  count      = var.test_worker_count > 0 ? 1 : 0
  role       = aws_iam_role.test_worker[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "test_worker" {
  count = var.test_worker_count > 0 ? 1 : 0
  name  = "${var.name_prefix}-test-worker"
  role  = aws_iam_role.test_worker[0].name
}

data "aws_vpc" "default" {
  count   = var.test_worker_count > 0 ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.test_worker_count > 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

resource "aws_security_group" "test_worker" {
  count       = var.test_worker_count > 0 ? 1 : 0
  name        = "${var.name_prefix}-test-worker"
  description = "PkgEval test workers: egress only"
  vpc_id      = data.aws_vpc.default[0].id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu" {
  count       = var.test_worker_count > 0 ? 1 : 0
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

resource "aws_instance" "test_worker" {
  count         = var.test_worker_count
  ami           = data.aws_ami.ubuntu[0].id
  instance_type = var.test_worker_instance_type
  subnet_id     = data.aws_subnets.default[0].ids[count.index % length(data.aws_subnets.default[0].ids)]

  vpc_security_group_ids = [aws_security_group.test_worker[0].id]
  iam_instance_profile   = aws_iam_instance_profile.test_worker[0].name

  metadata_options {
    http_tokens = "required" # IMDSv2 (AWS.jl supports it)
  }

  root_block_device {
    volume_size = var.test_worker_disk_gb
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/test_worker_userdata.sh.tpl", {
    region        = var.region
    queue_url     = aws_sqs_queue.jobs.url
    runs_table    = aws_dynamodb_table.runs.name
    jobs_table    = aws_dynamodb_table.jobs.name
    bucket        = aws_s3_bucket.results.bucket
    farm_repo     = var.test_worker_farm_repo
    farm_ref      = var.test_worker_farm_ref
    julia_channel = var.test_worker_julia_channel
  })

  tags = {
    Name = "${var.name_prefix}-test-worker-${count.index}"
  }
}
