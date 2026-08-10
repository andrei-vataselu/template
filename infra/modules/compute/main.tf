data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  # Pin via ami_id when set; otherwise follow the AL2023 ARM SSM parameter.
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.al2023_arm.value

  user_data_common = {
    project_name             = var.project_name
    origin_secret_arn        = var.origin_secret_arn
    db_app_secret_arn        = var.db_app_secret_arn
    db_host                  = var.db_host
    db_port                  = var.db_port
    db_name                  = var.db_name
    environment              = var.environment
    app_git_url              = var.app_git_url
    app_git_sha_param        = aws_ssm_parameter.app_git_sha.name
    cognito_region           = var.cognito_region
    cognito_user_pool_id     = var.cognito_user_pool_id
    cognito_spa_client_id    = var.cognito_spa_client_id
    cognito_hosted_ui_domain = var.cognito_hosted_ui_domain
    bootstrap_admin_emails   = var.bootstrap_admin_emails
    allowed_origins          = var.allowed_origins
    api_base_url             = var.api_base_url
    invite_only              = var.invite_only ? "1" : "0"
  }

  # Backend instances (ASG "app") run only the API; frontend instances
  # (ASG "web") run only the static site. Both sit behind the shared ALB.
  user_data_api = base64encode(templatefile("${path.module}/user_data.sh.tftpl",
  merge(local.user_data_common, { service_role = "api" })))
  user_data_web = base64encode(templatefile("${path.module}/user_data.sh.tftpl",
  merge(local.user_data_common, { service_role = "web" })))

  # Use HTTPS listener when we have a custom origin hostname + ACM cert
  https_enabled = var.origin_fqdn != ""
  # Host-based routing to the API target group (api-dev / api hostname)
  api_host_enabled = local.https_enabled && var.origin_api_fqdn != ""
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

# Deploy workflows write github.sha here before ASG instance refresh; user_data reads at boot.
# SSM String params cannot be empty — "unpinned" means shallow clone of default branch tip.
resource "aws_ssm_parameter" "app_git_sha" {
  name  = "/${var.project_name}/${var.environment}/app-git-sha"
  type  = "String"
  value = var.app_git_sha != "" ? var.app_git_sha : "unpinned"

  lifecycle {
    ignore_changes = [value]
  }

  tags = var.tags
}

resource "aws_iam_role_policy" "secrets_read" {
  name = "${var.project_name}-${var.environment}-secrets-read"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OriginAndDbAppSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = compact([var.origin_secret_arn, var.db_app_secret_arn])
      },
      {
        Sid    = "AppGitShaParam"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [aws_ssm_parameter.app_git_sha.arn]
      },
      {
        Sid      = "DenyRdsMaster"
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = ["arn:aws:secretsmanager:*:*:secret:rds!*"]
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
# Web instance role — least privilege: static frontend needs the origin
# header secret only (no DB secret, no Cognito admin APIs)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "web" {
  name = "${var.project_name}-${var.environment}-web"

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

resource "aws_iam_role_policy_attachment" "web_ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "web_cloudwatch" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "web" {
  name = "${var.project_name}-${var.environment}-web"
  role = aws_iam_role.web.name
  tags = var.tags
}

resource "aws_iam_role_policy" "web_secrets_read" {
  name = "${var.project_name}-${var.environment}-web-secrets-read"
  role = aws_iam_role.web.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OriginSecretOnly"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [var.origin_secret_arn]
      },
      {
        Sid    = "AppGitShaParam"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [aws_ssm_parameter.app_git_sha.arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Launch template + ASG (scale by changing desired; max caps the bill)
# ---------------------------------------------------------------------------

resource "aws_launch_template" "app" {
  name_prefix            = "${var.project_name}-${var.environment}-app-"
  update_default_version = true
  image_id               = local.ami_id
  instance_type          = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  # Private subnet — outbound via NAT Gateway (no public IP)
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = false
    security_groups             = [var.app_security_group_id]
    delete_on_termination       = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    # Docker bridge adds a hop; hop_limit=1 blocks IMDSv2 credentials inside containers.
    http_put_response_hop_limit = 2
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

  user_data = local.user_data_api

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

# Frontend instances — static site only, smaller instance type
resource "aws_launch_template" "web" {
  name_prefix            = "${var.project_name}-${var.environment}-web-"
  update_default_version = true
  image_id               = local.ami_id
  instance_type          = var.web_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.web.name
  }

  # Private subnet — outbound via NAT Gateway (no public IP).
  # Dedicated web SG: no database egress from frontend boxes.
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = false
    security_groups             = [var.web_security_group_id != "" ? var.web_security_group_id : var.app_security_group_id]
    delete_on_termination       = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    # Docker bridge adds a hop; hop_limit=1 blocks IMDSv2 credentials inside containers.
    http_put_response_hop_limit = 2
  }

  credit_specification {
    cpu_credits = "standard"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.web_root_volume_gb
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = local.user_data_web

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.project_name}-${var.environment}-web"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.project_name}-${var.environment}-web"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-${var.environment}-app"
  port     = 80
  protocol = "HTTP"
  # Pass vpc_id explicitly — looking it up via subnet data can defer to apply and
  # mark vpc_id unknown, which forces a needless TG replace (name collision).
  vpc_id = var.vpc_id

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

resource "aws_lb_target_group" "web" {
  name     = "${var.project_name}-${var.environment}-web"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-web-tg"
  })
}

resource "aws_autoscaling_group" "app" {
  name                = "${var.project_name}-${var.environment}-app"
  vpc_zone_identifier = var.app_subnet_ids
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  health_check_type   = "ELB"
  # First boot: dnf + docker image builds on t4g.micro often take 15–25m
  health_check_grace_period = 1800
  target_group_arns         = [aws_lb_target_group.app.arn]

  # Zero-downtime default for terraform-driven capacity / LT changes
  instance_refresh {
    strategy = "Rolling"
    preferences {
      # Keep old instance until new one is past first-boot docker builds.
      # ELB grace (30m) can mark instances "healthy" before /api/health works —
      # warmup must exceed typical cold boot or refresh causes 502 downtime.
      min_healthy_percentage = 100
      instance_warmup        = 2100
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

resource "aws_autoscaling_group" "web" {
  name                = "${var.project_name}-${var.environment}-web"
  vpc_zone_identifier = var.app_subnet_ids
  min_size            = var.web_asg_min_size
  max_size            = var.web_asg_max_size
  desired_capacity    = var.web_asg_desired_capacity
  health_check_type   = "ELB"
  # Vite build on a small instance can take a while on first boot
  health_check_grace_period = 1800
  target_group_arns         = [aws_lb_target_group.web.arn]

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 2100
    }
  }

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-web"
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
  subnets            = var.alb_subnet_ids

  # Idle timeout kept short — CloudFront holds the viewer connection
  idle_timeout = 60

  dynamic "access_logs" {
    for_each = var.access_logs_bucket != "" ? [1] : []
    content {
      bucket  = var.access_logs_bucket
      prefix  = var.access_logs_prefix
      enabled = true
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-alb"
  })
}

resource "aws_lb_listener" "http_forward" {
  count = local.https_enabled ? 0 : 1

  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  # Site traffic goes to the web instances; /api/* is routed to the API
  # instances by the listener rule below
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_lb_listener_rule" "http_api_path" {
  count = local.https_enabled ? 0 : 1

  listener_arn = aws_lb_listener.http_forward[0].arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
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
# Covers both the site origin and the API origin hostnames.
resource "aws_acm_certificate" "origin" {
  count = local.https_enabled ? 1 : 0

  domain_name               = var.origin_fqdn
  subject_alternative_names = var.origin_api_fqdn != "" ? [var.origin_api_fqdn] : []
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

# Static keys (not FQDNs): origin hostnames include random_id and are unknown on first plan.
resource "aws_route53_record" "origin_cert_validation" {
  for_each = !local.https_enabled ? {} : merge(
    { origin = var.origin_fqdn },
    local.api_host_enabled ? { origin_api = var.origin_api_fqdn } : {},
  )

  zone_id = var.zone_id
  name = one([
    for dvo in aws_acm_certificate.origin[0].domain_validation_options : dvo.resource_record_name
    if dvo.domain_name == each.value
  ])
  type = one([
    for dvo in aws_acm_certificate.origin[0].domain_validation_options : dvo.resource_record_type
    if dvo.domain_name == each.value
  ])
  records = [one([
    for dvo in aws_acm_certificate.origin[0].domain_validation_options : dvo.resource_record_value
    if dvo.domain_name == each.value
  ])]
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

  # Default: site (web instances). API traffic is split off by the rules below.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# api-dev / api hostname → API target group (CloudFront API distribution
# sends Host = origin_api_fqdn)
resource "aws_lb_listener_rule" "https_api_host" {
  count = local.api_host_enabled ? 1 : 0

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    host_header {
      values = [var.origin_api_fqdn]
    }
  }
}

# Same-origin /api/* stays working via the site host (health checks, legacy)
resource "aws_lb_listener_rule" "https_api_path" {
  count = local.https_enabled ? 1 : 0

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
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

# origin-api-dev.example.com → same ALB (CloudFront API origin hostname)
resource "aws_route53_record" "origin_api" {
  count = local.api_host_enabled ? 1 : 0

  zone_id = var.zone_id
  name    = var.origin_api_fqdn
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
    key = "tag:Name"
    values = [
      "${var.project_name}-${var.environment}-app",
      "${var.project_name}-${var.environment}-web",
    ]
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
