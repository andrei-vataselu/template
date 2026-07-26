output "arn" {
  description = "ARN of the resource group"
  value       = aws_resourcegroups_group.this.arn
}

output "name" {
  description = "Name of the resource group"
  value       = aws_resourcegroups_group.this.name
}
