output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.this.arn
}

output "spa_client_id" {
  value = aws_cognito_user_pool_client.spa.id
}

output "hosted_ui_domain" {
  description = "Hosted UI hostname (custom FQDN) or Cognito prefix (no dots)"
  value       = aws_cognito_user_pool_domain.this.domain
}

output "ses_domain_identity_arn" {
  value = try(aws_ses_domain_identity.mail[0].arn, null)
}

output "from_email_address" {
  value = var.from_email_address
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.cognito.arn
}
