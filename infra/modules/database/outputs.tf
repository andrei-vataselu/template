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
  value     = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
  sensitive = true
}
