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

output "asg_name" {
  description = "Backend (API) ASG"
  value       = module.compute.asg_name
}

output "web_asg_name" {
  description = "Frontend (web) ASG"
  value       = module.compute.web_asg_name
}

output "api_url" {
  value = module.edge.api_url
}

output "api_cloudfront_distribution_id" {
  value = module.edge.api_distribution_id
}

output "alb_dns_name" {
  value = module.compute.alb_dns_name
}

output "origin_domain" {
  value = module.compute.origin_domain_name
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

output "cognito_hosted_ui_domain" {
  value = module.cognito.hosted_ui_domain
}

output "cognito_user_pool_arn" {
  value = module.cognito.user_pool_arn
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
    4. Zero-downtime deploy: ./scripts/deploy.sh ${var.environment}
    5. Scale: set asg_desired_capacity in tfvars (cap = asg_max_size=${var.asg_max_size})
    6. SSM Session Manager for shell access (no SSH)
    7. App pin: deploy workflows write github.sha to ${module.compute.app_git_sha_parameter_name} before ASG rolls (optional tfvars seed: app_git_sha)
  EOT
}
