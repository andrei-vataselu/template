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
  value = aws_cognito_user_pool_domain.this.domain
}
