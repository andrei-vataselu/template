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
  value = module.compute.asg_name
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

output "budget_name" {
  value = module.observability.budget_name
}

output "resource_group_name" {
  value = module.resource_group_env.name
}

output "manual_next_steps" {
  value = <<-EOT
    1. Confirm SNS email subscription for ${var.alert_email}
    2. Attach CloudFront Free flat-rate plan to distribution ${module.edge.distribution_id}
    3. Open ${module.edge.site_url}
    4. Zero-downtime deploy: ./scripts/deploy.sh ${var.environment}
       (or: aws autoscaling start-instance-refresh --auto-scaling-group-name ${module.compute.asg_name})
    5. Scale (predictable): set asg_desired_capacity in tfvars (cap = asg_max_size=${var.asg_max_size})
    6. SSM Session Manager for shell access (no SSH)
  EOT
}
