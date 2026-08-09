data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    origin_secret_arn        = var.origin_secret_arn
    db_secret_arn            = var.db_secret_arn
    db_host                  = var.db_host
    db_port                  = var.db_port
    db_name                  = var.db_name
    environment              = var.environment
    app_git_url              = var.app_git_url
    cognito_region           = var.cognito_region
    cognito_user_pool_id     = var.cognito_user_pool_id
    cognito_spa_client_id    = var.cognito_spa_client_id
    cognito_hosted_ui_domain = var.cognito_hosted_ui_domain
    bootstrap_admin_emails   = var.bootstrap_admin_emails
  }))

  # Use HTTPS listener when we have a custom origin hostname + ACM cert
  https_enabled = var.origin_fqdn != ""
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

resource "aws_iam_role_policy" "secrets_read" {
  name = "${var.project_name}-${var.environment}-secrets-read"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TaggedAppSecrets"
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
      },
      {
        Sid      = "RdsMasterSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [var.db_secret_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "cognito_admin" {
  name = "${var.project_name}-${var.environment}-cognito-admin"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CognitoUserAdmin"
      Effect = "Allow"
      Action = [
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminDeleteUser",
        "cognito-idp:AdminDisableUser",
        "cognito-idp:AdminEnableUser",
        "cognito-idp:AdminGetUser",
        "cognito-idp:AdminListGroupsForUser",
        "cognito-idp:AdminAddUserToGroup",
        "cognito-idp:AdminRemoveUserFromGroup",
        "cognito-idp:ListUsers",
        "cognito-idp:DescribeUserPool",
        "cognito-idp:DescribeUserPoolClient"
      ]
      Resource = [var.cognito_user_pool_arn]
    }]
  })
}

# ---------------------------------------------------------------------------
# Launch template + ASG (scale by changing desired; max caps the bill)
# ---------------------------------------------------------------------------

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project_name}-${var.environment}-app-"
  image_id      = data.aws_ssm_parameter.al2023_arm.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  # Public IP for outbound (dnf/docker/git) without a NAT gateway
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = true
    security_groups             = [var.app_security_group_id]
    delete_on_termination       = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  credit_specification {
    cpu_credits = "standard"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_gb
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = local.user_data

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.project_name}-${var.environment}-app"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.project_name}-${var.environment}-app"
    })
  }

  # user_data / AMI changes create a new LT version; instance refresh rolls it out
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-${var.environment}-app"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_subnet.first.vpc_id

  health_check {
    enabled             = true
    path                = "/api/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-app-tg"
  })
}

data "aws_subnet" "first" {
  id = var.subnet_ids[0]
}

resource "aws_autoscaling_group" "app" {
  name                      = "${var.project_name}-${var.environment}-app"
  vpc_zone_identifier       = var.subnet_ids
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  health_check_type         = "ELB"
  # First boot: dnf + docker image builds on t4g.micro often take 15–25m
  health_check_grace_period = 1800
  target_group_arns         = [aws_lb_target_group.app.arn]

  # Zero-downtime default for terraform-driven capacity / LT changes
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 300
    }
  }

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-app"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# ALB — stable origin for CloudFront; enables rolling deploys + horizontal scale
# ---------------------------------------------------------------------------

resource "aws_lb" "app" {
  name               = "${var.project_name}-${var.environment}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.alb_security_group_id]
  subnets            = var.subnet_ids

  # Idle timeout kept short — CloudFront holds the viewer connection
  idle_timeout = 60

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-alb"
  })
}

resource "aws_lb_listener" "http_forward" {
  count = local.https_enabled ? 0 : 1

  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Regional ACM cert for the ALB (CloudFront viewer cert stays in us-east-1 / edge module)
resource "aws_acm_certificate" "origin" {
  count = local.https_enabled ? 1 : 0

  domain_name       = var.origin_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_route53_record" "origin_cert_validation" {
  for_each = local.https_enabled ? {
    for dvo in aws_acm_certificate.origin[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "origin" {
  count = local.https_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.origin[0].arn
  validation_record_fqdns = [for r in aws_route53_record.origin_cert_validation : r.fqdn]
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.origin[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# origin-dev.example.com → ALB (CloudFront origin hostname)
resource "aws_route53_record" "origin" {
  count = local.https_enabled ? 1 : 0

  zone_id = var.zone_id
  name    = var.origin_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# Weekly OS patching — targets ASG instances by tag (not a fixed instance id)
# ---------------------------------------------------------------------------

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
    key    = "tag:Name"
    values = ["${var.project_name}-${var.environment}-app"]
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
