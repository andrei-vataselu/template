/*
  Shared DEV/PROD architecture = guide "Lower-cost compromise"
  (NOT CloudFront Business private VPC origin — that alone is $200/mo)

  Same in every env:
  - VPC: 2 public app AZs + 2 private DB AZs, IGW on public only, no NAT
  - S3 gateway endpoint only (no interface endpoints)
  - App SG: CloudFront prefix list only, no SSH/RDP
  - DB SG: app SG only, private, SSL forced, encrypted
  - CloudFront + WAF + origin secret header + Docker on EC2
  - Cognito (no SMS, no public signup), budgets/SNS, resource groups

  Differs by env vars only:
  - instance sizes, CloudFront plan (manual), multi_az, deletion_protection, backups

  COST GATE (eu-west-1, no free-tier): see ../../COST_GATE.txt
  DEV expected ~$28–30/mo (public IPv4 included). $25 alert will trip.
  Guide Business/private-origin PROD ~$245+/mo.
*/

data "aws_availability_zones" "available" {
  state = "available"
}

resource "random_password" "origin_header" {
  length  = 32
  special = false
}

# Origin secret lives in Secrets Manager; EC2 fetches it at boot via its role
# instead of having it baked into user-data (readable through the EC2 API).
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

  # dev.<domain> for users, origin-dev.<domain> for CloudFront -> EC2 TLS
  site_fqdn   = var.domain_name != "" ? "dev.${var.domain_name}" : ""
  origin_fqdn = var.domain_name != "" ? "origin-dev.${var.domain_name}" : ""

  common_tags = {
    Application = var.application_name
    Environment = var.environment
  }
}

# Zone is created by infra/global — apply that stack (and switch the
# registrar's nameservers to Route 53) before enabling domain_name here
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

module "compute" {
  source = "../../modules/compute"

  project_name      = var.project_name
  environment       = var.environment
  subnet_id         = module.networking.public_subnet_ids[0]
  security_group_id = module.security_groups.app_security_group_id
  instance_type     = var.instance_type
  root_volume_gb    = var.root_volume_gb
  origin_secret_arn = aws_secretsmanager_secret.origin_header.arn
  app_git_url       = var.app_git_url
  origin_fqdn       = local.origin_fqdn
  zone_id           = var.domain_name != "" ? data.aws_route53_zone.main[0].zone_id : ""
  certbot_email     = var.alert_email
  tags              = local.common_tags

  depends_on = [aws_secretsmanager_secret_version.origin_header]
}

# CloudFront resolves the origin hostname publicly, so it must point at the EIP
resource "aws_route53_record" "origin" {
  count = var.domain_name != "" ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = local.origin_fqdn
  type    = "A"
  ttl     = 300
  records = [module.compute.public_ip]
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

module "edge" {
  source = "../../modules/edge"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  project_name        = var.project_name
  environment         = var.environment
  origin_domain_name  = var.domain_name != "" ? local.origin_fqdn : module.compute.public_dns
  origin_https        = var.domain_name != ""
  aliases             = var.domain_name != "" ? [local.site_fqdn] : []
  zone_id             = var.domain_name != "" ? data.aws_route53_zone.main[0].zone_id : ""
  origin_header_name  = local.origin_header_name
  origin_header_value = random_password.origin_header.result
  allowed_ip_cidrs    = var.allowed_ip_cidrs
  tags                = local.common_tags
}

module "cognito" {
  source = "../../modules/cognito"

  project_name        = var.project_name
  environment         = var.environment
  require_mfa         = true
  deletion_protection = var.environment == "prod"
  callback_urls = concat(
    var.domain_name != "" ? ["https://${local.site_fqdn}/callback"] : [],
    [
      "https://${module.edge.distribution_domain_name}/callback",
      "https://localhost/callback",
    ]
  )
  logout_urls = concat(
    var.domain_name != "" ? ["https://${local.site_fqdn}/logout"] : [],
    [
      "https://${module.edge.distribution_domain_name}/logout",
      "https://localhost/logout",
    ]
  )
  tags = local.common_tags
}

module "observability" {
  source = "../../modules/observability"

  project_name       = var.project_name
  environment        = var.environment
  monthly_budget_usd = var.monthly_budget_usd
  alert_email        = var.alert_email
  ec2_instance_id    = module.compute.instance_id
  db_instance_id     = module.database.db_instance_id
  tags               = local.common_tags
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
