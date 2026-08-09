output "db_instance_id" {
  value = aws_db_instance.this.id
}

output "db_endpoint" {
  value = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "master_user_secret_arn" {
  description = "RDS-managed master secret — ensure-app Lambda / break-glass only (not on EC2)"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
  sensitive   = true
}

output "app_user_secret_arn" {
  description = "Tagged app runtime DB credentials (username=app)"
  value       = aws_secretsmanager_secret.app.arn
  sensitive   = true
}

output "ensure_app_lambda_name" {
  value = aws_lambda_function.ensure_app.function_name
}
