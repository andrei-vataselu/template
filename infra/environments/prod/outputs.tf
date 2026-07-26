output "aws_region" {
  value = var.aws_region
}

output "site_url" {
  value = module.edge.site_url
}

output "cloudfront_domain" {
  value = module.edge.distribution_domain_name
}

output "cloudfront_distribution_id" {
  value = module.edge.distribution_id
}

output "ec2_instance_id" {
  value = module.compute.instance_id
}

output "ec2_public_dns" {
  value = module.compute.public_dns
}

output "rds_endpoint" {
  value = module.database.db_endpoint
}

output "cognito_user_pool_id" {
  value = module.cognito.user_pool_id
}

output "cognito_spa_client_id" {
  value = module.cognito.spa_client_id
}

output "budget_name" {
  value = module.observability.budget_name
}

output "resource_group_name" {
  value = module.resource_group_env.name
}

output "manual_next_steps" {
  value = <<-EOT
    1. Confirm SNS email subscription for ${var.alert_email}
    2. Attach CloudFront Pro flat-rate plan to distribution ${module.edge.distribution_id}
    3. Open ${module.edge.site_url}
    4. Local full stack: cd deploy && copy .env.example .env && docker compose up --build
    5. For full React/Node on EC2: push repo, set app_git_url in terraform.tfvars, replace instance
    6. SSM Session Manager for shell access (no SSH)
  EOT
}
