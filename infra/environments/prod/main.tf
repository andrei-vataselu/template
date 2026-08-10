/*
  Shared DEV/PROD architecture — same as environments/dev (ALB + private ASG + NAT).
  Differs by size/HA vars only. COST GATE: ../../COST_GATE.txt
  PROD expected ~$157–172/mo with NAT + split FE/BE.
*/

data "aws_availability_zones" "available" {
  state = "available"
}

resource "random_password" "origin_header" {
  length  = 32
  special = false
}

resource "random_id" "origin_dns" {
  byte_length = 4
}

resource "aws_secretsmanager_secret" "origin_header" {
  name_prefix             = "${var.project_name}-${var.environment}-origin-header-"
  description             = "CloudFront origin verification header (JSON current/previous; rotated daily)"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "origin_header" {
  secret_id = aws_secretsmanager_secret.origin_header.id
  secret_string = jsonencode({
    current  = random_password.origin_header.result
    previous = random_password.origin_header.result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_secretsmanager_secret_version" "origin_header_live" {
  secret_id  = aws_secretsmanager_secret.origin_header.id
  depends_on = [aws_secretsmanager_secret_version.origin_header]
}

locals {
  azs                = slice(data.aws_availability_zones.available.names, 0, 2)
  origin_header_name = "X-Origin-Verify"
  _origin_raw        = data.aws_secretsmanager_secret_version.origin_header_live.secret_string
  _origin_obj        = try(jsondecode(local._origin_raw), null)
  origin_header_current = (
    local._origin_obj != null
    ? local._origin_obj.current
    : local._origin_raw
  )

  site_fqdn       = var.domain_name
  aliases         = var.domain_name != "" ? [var.domain_name, "www.${var.domain_name}"] : []
  origin_fqdn     = var.domain_name != "" ? "o-${random_id.origin_dns.hex}.${var.domain_name}" : ""
  auth_fqdn       = var.domain_name != "" ? "auth.${var.domain_name}" : ""
  api_fqdn        = var.domain_name != "" ? "api.${var.domain_name}" : ""
  origin_api_fqdn = var.domain_name != "" ? "oa-${random_id.origin_dns.hex}.${var.domain_name}" : ""

  # Browser origins the API accepts (CORS) — apex + www only
  allowed_origins = var.domain_name != "" ? join(",", [
    "https://${var.domain_name}",
    "https://www.${var.domain_name}",
  ]) : ""

  # Served by CloudFront for the SPA: limits XSS blast radius (tokens live in
  # sessionStorage). connect-src covers the API host + Cognito endpoints;
  # Google Fonts are loaded by index.html.
  content_security_policy = var.domain_name != "" ? join("; ", [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' data: https://fonts.gstatic.com",
    "img-src 'self' data:",
    "object-src 'none'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
    "form-action 'self'",
    "connect-src 'self' https://${local.api_fqdn} https://${local.auth_fqdn} https://cognito-idp.${var.aws_region}.amazonaws.com https://*.amazoncognito.com",
    "upgrade-insecure-requests",
  ]) : ""

  common_tags = {
    Application = var.application_name
    Environment = var.environment
  }
}

data "aws_route53_zone" "main" {
  count = var.domain_name != "" ? 1 : 0
  name  = var.domain_name
}

module "networking" {
  source = "../../modules/networking"

  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr
  azs          = local.azs
  tags         = local.common_tags
}

module "security_groups" {
  source = "../../modules/security_groups"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.networking.vpc_id
  tags         = local.common_tags
}

module "access_logs" {
  source = "../../modules/access_logs"

  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}

module "database" {
  source = "../../modules/database"

  project_name                   = var.project_name
  environment                    = var.environment
  vpc_id                         = module.networking.vpc_id
  subnet_ids                     = module.networking.private_db_subnet_ids
  lambda_subnet_ids              = module.networking.private_app_subnet_ids
  security_group_id              = module.security_groups.db_security_group_id
  instance_class                 = var.db_instance_class
  allocated_storage_gb           = var.db_storage_gb
  backup_retention_days          = var.backup_retention_days
  multi_az                       = var.db_multi_az
  deletion_protection            = var.db_deletion_protection
  skip_final_snapshot            = var.db_skip_final_snapshot
  secret_recovery_window_in_days = 7
  tags                           = local.common_tags
}

module "cognito" {
  source = "../../modules/cognito"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  project_name = var.project_name
  environment  = var.environment
  require_mfa  = true
  # Invite-only (admin creates users) — matches the documented security posture
  allow_self_signup      = false
  deletion_protection    = var.environment == "prod"
  custom_auth_domain     = local.auth_fqdn
  zone_id                = var.domain_name != "" ? data.aws_route53_zone.main[0].zone_id : ""
  ses_email_domain       = var.domain_name
  from_email_address     = var.domain_name != "" ? "noreply@${var.domain_name}" : ""
  reply_to_email_address = var.alert_email
  # Flip to true after SES production access is approved
  ses_cognito_mail_enabled = false
  # Production redirect URIs only — no localhost on the prod pool
  callback_urls = concat(
    var.domain_name != "" ? ["https://${local.site_fqdn}/callback"] : [],
    var.domain_name != "" ? ["https://www.${var.domain_name}/callback"] : [],
  )
  logout_urls = concat(
    var.domain_name != "" ? ["https://${local.site_fqdn}/logout"] : [],
    var.domain_name != "" ? ["https://www.${var.domain_name}/logout"] : [],
  )
  allowed_ip_cidrs = concat(
    var.allowed_ip_cidrs,
    module.networking.nat_public_ip != "" ? ["${module.networking.nat_public_ip}/32"] : [],
  )
  allowed_ipv6_cidrs = var.allowed_ipv6_cidrs
  tags               = local.common_tags
}

module "compute" {
  source = "../../modules/compute"

  project_name             = var.project_name
  environment              = var.environment
  vpc_id                   = module.networking.vpc_id
  alb_subnet_ids           = module.networking.public_subnet_ids
  app_subnet_ids           = module.networking.private_app_subnet_ids
  alb_security_group_id    = module.security_groups.alb_security_group_id
  app_security_group_id    = module.security_groups.app_security_group_id
  web_security_group_id    = module.security_groups.web_security_group_id
  instance_type            = var.instance_type
  web_instance_type        = var.web_instance_type
  root_volume_gb           = var.root_volume_gb
  ami_id                   = var.ami_id
  origin_secret_arn        = aws_secretsmanager_secret.origin_header.arn
  db_app_secret_arn        = module.database.app_user_secret_arn
  db_host                  = module.database.db_endpoint
  db_port                  = module.database.db_port
  cognito_region           = var.aws_region
  cognito_user_pool_id     = module.cognito.user_pool_id
  cognito_user_pool_arn    = module.cognito.user_pool_arn
  cognito_spa_client_id    = module.cognito.spa_client_id
  cognito_hosted_ui_domain = module.cognito.hosted_ui_domain
  bootstrap_admin_emails   = var.alert_email
  invite_only              = true
  app_git_url              = var.app_git_url
  app_git_sha              = var.app_git_sha
  origin_fqdn              = local.origin_fqdn
  origin_api_fqdn          = local.origin_api_fqdn
  allowed_origins          = local.allowed_origins
  # Same-origin /api via site host (ALB path rule) — see dev comment.
  api_base_url             = ""
  zone_id                  = var.domain_name != "" ? data.aws_route53_zone.main[0].zone_id : ""
  asg_min_size             = var.asg_min_size
  asg_desired_capacity     = var.asg_desired_capacity
  asg_max_size             = var.asg_max_size
  web_asg_min_size         = var.web_asg_min_size
  web_asg_desired_capacity = var.web_asg_desired_capacity
  web_asg_max_size         = var.web_asg_max_size
  access_logs_bucket       = module.access_logs.bucket_id
  access_logs_prefix       = module.access_logs.alb_logs_prefix
  tags                     = local.common_tags

  depends_on = [
    aws_secretsmanager_secret_version.origin_header,
    module.database,
    module.cognito,
    module.access_logs,
  ]
}

module "alb_waf" {
  source = "../../modules/alb_waf"

  project_name = var.project_name
  environment  = var.environment
  alb_arn      = module.compute.alb_arn
  tags         = local.common_tags
}

module "edge" {
  source = "../../modules/edge"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  project_name                   = var.project_name
  environment                    = var.environment
  origin_domain_name             = module.compute.origin_domain_name
  origin_https                   = module.compute.origin_https
  aliases                        = local.aliases
  api_aliases                    = local.api_fqdn != "" ? [local.api_fqdn] : []
  api_origin_domain_name         = module.compute.origin_api_domain_name
  content_security_policy        = local.content_security_policy
  zone_id                        = var.domain_name != "" ? data.aws_route53_zone.main[0].zone_id : ""
  origin_header_name             = local.origin_header_name
  origin_header_value            = local.origin_header_current
  allowed_ip_cidrs               = var.allowed_ip_cidrs
  access_logs_bucket             = module.access_logs.bucket_id
  access_logs_bucket_domain_name = module.access_logs.bucket_domain_name
  access_logs_prefix             = module.access_logs.cloudfront_logs_prefix
  tags                           = local.common_tags
}

module "observability" {
  source = "../../modules/observability"

  project_name                = var.project_name
  environment                 = var.environment
  monthly_budget_usd          = var.monthly_budget_usd
  alert_email                 = var.alert_email
  enable_web_alarms           = true
  asg_name                    = module.compute.asg_name
  web_asg_name                = module.compute.web_asg_name
  alb_arn_suffix              = module.compute.alb_arn_suffix
  target_group_arn_suffix     = module.compute.target_group_arn_suffix
  web_target_group_arn_suffix = module.compute.web_target_group_arn_suffix
  db_instance_id              = module.database.db_instance_id
  tags                        = local.common_tags
}

module "origin_rotate" {
  source = "../../modules/origin_rotate"

  project_name          = var.project_name
  environment           = var.environment
  origin_secret_arn     = aws_secretsmanager_secret.origin_header.arn
  origin_header_name    = local.origin_header_name
  site_distribution_id  = module.edge.distribution_id
  site_distribution_arn = module.edge.distribution_arn
  api_distribution_id   = module.edge.api_distribution_id
  api_distribution_arn  = module.edge.api_distribution_arn
  alert_topic_arn       = module.observability.sns_topic_arn
  app_asg_name          = module.compute.asg_name
  web_asg_name          = module.compute.web_asg_name
  tags                  = local.common_tags
}

module "resource_group_env" {
  source = "../../modules/resource_group"

  name        = "${var.application_name}-${var.environment}"
  description = "All ${var.application_name} resources in ${var.environment}"

  tag_filters = [
    {
      key    = "Application"
      values = [var.application_name]
    },
    {
      key    = "Environment"
      values = [var.environment]
    }
  ]

  tags = local.common_tags
}
