# Guide §7: Cognito — email via SES, optional self-signup, PKCE SPA client

resource "aws_cognito_user_pool" "this" {
  name = "${var.project_name}-${var.environment}"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = var.require_mfa ? "ON" : "OPTIONAL"

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 3
  }

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = !var.allow_self_signup
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  dynamic "email_configuration" {
    for_each = local.use_ses_mail ? [1] : []
    content {
      email_sending_account  = "DEVELOPER"
      source_arn             = aws_ses_domain_identity.mail[0].arn
      from_email_address     = var.from_email_address
      reply_to_email_address = var.reply_to_email_address != "" ? var.reply_to_email_address : null
    }
  }

  # Until SES leaves the sandbox, Cognito's default mailer can reach any inbox.
  dynamic "email_configuration" {
    for_each = local.use_ses_mail ? [] : [1]
    content {
      email_sending_account = "COGNITO_DEFAULT"
    }
  }

  deletion_protection = var.deletion_protection ? "ACTIVE" : "INACTIVE"

  tags = var.tags

  depends_on = [
    aws_ses_domain_dkim.mail,
    aws_ses_identity_policy.cognito,
    aws_ses_domain_identity_verification.mail,
  ]
}

resource "aws_cognito_user_pool_ui_customization" "this" {
  user_pool_id = aws_cognito_user_pool.this.id
  client_id    = aws_cognito_user_pool_client.spa.id

  css = <<-CSS
    .banner-customizable { background: linear-gradient(160deg, #f7f3ea 0%, #e7efe8 100%); }
    .logo-customizable { max-width: 8rem; }
    .label-customizable { font-weight: 700; color: #0f3d30; }
    .inputField-customizable { border-radius: 0; border-color: rgba(18,32,28,0.18); }
    .submitButton-customizable { background-color: #0f3d30; border-color: #0f3d30; border-radius: 0; font-weight: 700; }
    .submitButton-customizable:hover { background-color: #1f6f54; border-color: #1f6f54; }
    .redirect-customizable, .legalText-customizable { color: #0f3d30; }
    .background-customizable { background: #f3efe4; }
    .idpDescription-customizable, .idpButton-customizable { border-radius: 0; }
  CSS

  depends_on = [aws_cognito_user_pool_domain.this]
}

resource "aws_cognito_user_pool_client" "spa" {
  name         = "${var.project_name}-${var.environment}-spa"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = false
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = var.callback_urls
  logout_urls                          = var.logout_urls
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 7

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  use_custom_domain = var.custom_auth_domain != ""
  use_ses           = var.ses_email_domain != ""
  # SES domain can be verified while the account is still in sandbox; Cognito
  # DEVELOPER sends only work to verified recipients until production access.
  use_ses_mail = local.use_ses && var.ses_cognito_mail_enabled
}

# ---------------------------------------------------------------------------
# SES — Cognito sends verification / forgot-password from your domain
# ---------------------------------------------------------------------------

resource "aws_ses_domain_identity" "mail" {
  count  = local.use_ses ? 1 : 0
  domain = var.ses_email_domain
}

resource "aws_ses_domain_dkim" "mail" {
  count  = local.use_ses ? 1 : 0
  domain = aws_ses_domain_identity.mail[0].domain
}

resource "aws_route53_record" "ses_verification" {
  count = local.use_ses ? 1 : 0

  zone_id = var.zone_id
  name    = "_amazonses.${var.ses_email_domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.mail[0].verification_token]
}

resource "aws_route53_record" "ses_dkim" {
  count = local.use_ses ? 3 : 0

  zone_id = var.zone_id
  name    = "${aws_ses_domain_dkim.mail[0].dkim_tokens[count.index]}._domainkey.${var.ses_email_domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.mail[0].dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_ses_domain_identity_verification" "mail" {
  count  = local.use_ses ? 1 : 0
  domain = aws_ses_domain_identity.mail[0].id

  depends_on = [aws_route53_record.ses_verification]
}

# Sandbox-friendly: also verify the reply-to / bootstrap inbox so mail can deliver
resource "aws_ses_email_identity" "reply_to" {
  count = local.use_ses && var.reply_to_email_address != "" ? 1 : 0
  email = var.reply_to_email_address
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ses_identity_policy" "cognito" {
  count = local.use_ses ? 1 : 0

  identity = aws_ses_domain_identity.mail[0].arn
  name     = "${var.project_name}-${var.environment}-cognito-send"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCognitoSend"
      Effect = "Allow"
      Principal = {
        Service = "cognito-idp.amazonaws.com"
      }
      Action = [
        "ses:SendEmail",
        "ses:SendRawEmail",
      ]
      Resource = aws_ses_domain_identity.mail[0].arn
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# Hosted UI domain (custom FQDN needs ACM in us-east-1 — CloudFront-backed)
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "auth" {
  count    = local.use_custom_domain ? 1 : 0
  provider = aws.us_east_1

  domain_name       = var.custom_auth_domain
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "auth_cert_validation" {
  for_each = local.use_custom_domain ? {
    for dvo in aws_acm_certificate.auth[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.zone_id
}

resource "aws_acm_certificate_validation" "auth" {
  count    = local.use_custom_domain ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.auth[0].arn
  validation_record_fqdns = [for r in aws_route53_record.auth_cert_validation : r.fqdn]
}

resource "aws_cognito_user_pool_domain" "this" {
  domain          = local.use_custom_domain ? var.custom_auth_domain : "${var.project_name}-${var.environment}-${random_id.suffix.hex}"
  user_pool_id    = aws_cognito_user_pool.this.id
  certificate_arn = local.use_custom_domain ? aws_acm_certificate_validation.auth[0].certificate_arn : null
}

resource "aws_route53_record" "auth_a" {
  count = local.use_custom_domain ? 1 : 0

  zone_id = var.zone_id
  name    = var.custom_auth_domain
  type    = "A"

  alias {
    name                   = aws_cognito_user_pool_domain.this.cloudfront_distribution
    zone_id                = aws_cognito_user_pool_domain.this.cloudfront_distribution_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "auth_aaaa" {
  count = local.use_custom_domain ? 1 : 0

  zone_id = var.zone_id
  name    = var.custom_auth_domain
  type    = "AAAA"

  alias {
    name                   = aws_cognito_user_pool_domain.this.cloudfront_distribution
    zone_id                = aws_cognito_user_pool_domain.this.cloudfront_distribution_zone_id
    evaluate_target_health = false
  }
}

resource "aws_cognito_user_group" "admins" {
  name         = "admins"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Application administrators"
}
