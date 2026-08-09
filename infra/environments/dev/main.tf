/*
  Shared DEV/PROD architecture = guide "Lower-cost compromise"
  (NOT CloudFront Business private VPC origin — that alone is $200/mo)

  Same in every env:
  - VPC: 2 public app AZs + 2 private DB AZs, IGW on public only, no NAT
  - S3 gateway endpoint only (no interface endpoints)
  - ALB SG: CloudFront prefix list only; App SG: ALB only; no SSH/RDP
  - ASG (desired=1, max capped) + ALB for zero-downtime rolling deploys
  - CloudFront + WAF + origin secret header + Docker on EC2
  - Cognito (no SMS, no public signup), budgets/SNS, resource groups

  Differs by env vars only:
  - instance sizes, CloudFront plan (manual), multi_az, deletion_protection, backups, ASG max

  COST GATE (eu-west-1, no free-tier): see ../../COST_GATE.txt
  DEV expected ~$52–55/mo with ALB (was ~$28–30 without). Scale by raising asg_desired.
*/

data "aws_availability_zones" "available" {
  state = "available"
}

resource "random_password" "origin_header" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "origin_header" {
  name_prefix             = "${var.project_name}-${var.environment}-origin-header-"
  description             = "CloudFront origin verification header value"
  recovery_window_in_days = 0
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "origin_header" {
  secret_id     = aws_secretsmanager_secret.origin_header.id
  secret_string = random_password.origin_header.result
}

locals {
  azs                = slice(data.aws_availability_zones.available.names, 0, 2)
  origin_header_name = "X-Origin-Verify"

  site_fqdn   = var.domain_name != "" ? "dev.${var.domain_name}" : ""
  origin_fqdn = var.domain_name != "" ? "origin-dev.${var.domain_name}" : ""

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

module "database" {
  source = "../../modules/database"

  project_name          = var.project_name
  environment           = var.environment
  subnet_ids            = module.networking.private_db_subnet_ids
  security_group_id     = module.security_groups.db_security_group_id
  instance_class        = var.db_instance_class
  allocated_storage_gb  = var.db_storage_gb
  backup_retention_days = var.backup_retention_days
  multi_az              = var.db_multi_az
  deletion_protection   = var.db_deletion_protection
  skip_final_snapshot   = var.db_skip_final_snapshot
  tags                  = local.common_tags
}

# Cognito before compute so EC2 boots with pool/client IDs.
# Callbacks use the custom domain (CloudFront aliases it) — avoids edge↔compute cycle.
module "cognito" {
  source = "../../modules/cognito"

  project_name        = var.project_name
  environment         = var.environment
  require_mfa         = true
  deletion_protection = var.environment == "prod"
  callback_urls = concat(
    var.domain_name != "" ? ["https://${local.site_fqdn}/callback"] : [],
    [
      "https://localhost/callback",
      "http://localhost:5173/callback",
    ]
  )
  logout_urls = concat(
    var.domain_name != "" ? ["https://${local.site_fqdn}/logout"] : [],
    [
      "https://localhost/logout",
      "http://localhost:5173/logout",
    ]
  )
  tags = local.common_tags
}

module "compute" {
  source = "../../modules/compute"

  project_name             = var.project_name
  environment              = var.environment
  subnet_ids               = module.networking.public_subnet_ids
  alb_security_group_id    = module.security_groups.alb_security_group_id
  app_security_group_id    = module.security_groups.app_security_group_id
  instance_type            = var.instance_type
  root_volume_gb           = var.root_volume_gb
  origin_secret_arn        = aws_secretsmanager_secret.origin_header.arn
  db_secret_arn            = module.database.master_user_secret_arn
  cognito_region           = var.aws_region
  cognito_user_pool_id     = module.cognito.user_pool_id
  cognito_user_pool_arn    = module.cognito.user_pool_arn
  cognito_spa_client_id    = module.cognito.spa_client_id
  cognito_hosted_ui_domain = module.cognito.hosted_ui_domain
  bootstrap_admin_emails   = var.alert_email
  app_git_url              = var.app_git_url
  origin_fqdn              = local.origin_fqdn
  zone_id                  = var.domain_name != "" ? data.aws_route53_zone.main[0].zone_id : ""
  asg_min_size             = var.asg_min_size
  asg_desired_capacity     = var.asg_desired_capacity
  asg_max_size             = var.asg_max_size
  tags                     = local.common_tags

  depends_on = [
    aws_secretsmanager_secret_version.origin_header,
    module.database,
    module.cognito,
  ]
}

module "edge" {
  source = "../../modules/edge"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  project_name        = var.project_name
  environment         = var.environment
  origin_domain_name  = module.compute.origin_domain_name
  origin_https        = module.compute.origin_https
  aliases             = var.domain_name != "" ? [local.site_fqdn] : []
  zone_id             = var.domain_name != "" ? data.aws_route53_zone.main[0].zone_id : ""
  origin_header_name  = local.origin_header_name
  origin_header_value = random_password.origin_header.result
  allowed_ip_cidrs    = var.allowed_ip_cidrs
  tags                = local.common_tags
}

module "observability" {
  source = "../../modules/observability"

  project_name            = var.project_name
  environment             = var.environment
  monthly_budget_usd      = var.monthly_budget_usd
  alert_email             = var.alert_email
  asg_name                = module.compute.asg_name
  alb_arn_suffix          = module.compute.alb_arn_suffix
  target_group_arn_suffix = module.compute.target_group_arn_suffix
  db_instance_id          = module.database.db_instance_id
  tags                    = local.common_tags
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
