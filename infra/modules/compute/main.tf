data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_iam_role" "app" {
  name = "${var.project_name}-${var.environment}-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-${var.environment}-app"
  role = aws_iam_role.app.name
  tags = var.tags
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.al2023_arm.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data_base64 = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    origin_secret_arn = var.origin_secret_arn
    environment       = var.environment
    app_git_url       = var.app_git_url
    origin_fqdn       = var.origin_fqdn
    certbot_email     = var.certbot_email
  }))

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-app"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# Stable public endpoint: without an EIP the auto-assigned IP/DNS changes on
# stop/start and CloudFront would keep pointing at a dead hostname.
# No extra cost — the public IPv4 hourly charge applies either way.
resource "aws_eip" "app" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-app-eip"
  })
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}

# Certbot DNS-01: HTTP-01 can't work because the SG only admits CloudFront IPs,
# so the instance proves domain ownership by writing a TXT record instead
resource "aws_iam_role_policy" "certbot_dns01" {
  count = var.origin_fqdn != "" ? 1 : 0

  name = "${var.project_name}-${var.environment}-certbot-dns01"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:GetChange"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.zone_id}"
      }
    ]
  })
}

# Ongoing OS patching: weekly SSM patch window instead of only patching at boot.
# Free — runs through the SSM agent already on the instance. May reboot Sunday
# 03:00 UTC; the compose systemd unit brings the containers back automatically.
resource "aws_ssm_maintenance_window" "patching" {
  name              = "${var.project_name}-${var.environment}-weekly-patching"
  schedule          = "cron(0 3 ? * SUN *)"
  schedule_timezone = "UTC"
  duration          = 2
  cutoff            = 1
  tags              = var.tags
}

resource "aws_ssm_maintenance_window_target" "app" {
  window_id     = aws_ssm_maintenance_window.patching.id
  name          = "${var.project_name}-${var.environment}-app"
  resource_type = "INSTANCE"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.app.id]
  }
}

resource "aws_ssm_maintenance_window_task" "patch" {
  window_id       = aws_ssm_maintenance_window.patching.id
  name            = "${var.project_name}-${var.environment}-patch"
  task_type       = "RUN_COMMAND"
  task_arn        = "AWS-RunPatchBaseline"
  priority        = 1
  max_concurrency = "1"
  max_errors      = "0"

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.app.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      timeout_seconds = 3600

      parameter {
        name   = "Operation"
        values = ["Install"]
      }

      parameter {
        name   = "RebootOption"
        values = ["RebootIfNeeded"]
      }
    }
  }
}

resource "aws_iam_role_policy" "secrets_read" {
  name = "${var.project_name}-${var.environment}-secrets-read"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = "*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/Application" = lookup(var.tags, "Application", "template")
          "aws:ResourceTag/Environment" = var.environment
        }
      }
    }]
  })
}
