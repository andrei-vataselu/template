# Guide §7: Cognito Lite-style settings — no SMS, no public sign-up, PKCE SPA client

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
    allow_admin_create_user_only = true
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  deletion_protection = var.deletion_protection ? "ACTIVE" : "INACTIVE"

  tags = var.tags
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

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.project_name}-${var.environment}-${random_id.suffix.hex}"
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_cognito_user_group" "admins" {
  name         = "admins"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Application administrators"
}
