output "alb_arn_suffix" {
  value = aws_lb.app.arn_suffix
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.app.arn_suffix
}

output "web_target_group_arn_suffix" {
  value = aws_lb_target_group.web.arn_suffix
}

output "asg_name" {
  description = "Backend (API) ASG"
  value       = aws_autoscaling_group.app.name
}

output "web_asg_name" {
  description = "Frontend (web) ASG"
  value       = aws_autoscaling_group.web.name
}

output "launch_template_id" {
  value = aws_launch_template.app.id
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "alb_arn" {
  value = aws_lb.app.arn
}

output "alb_zone_id" {
  value = aws_lb.app.zone_id
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "origin_domain_name" {
  description = "Hostname CloudFront should use as origin (site)"
  value       = var.origin_fqdn != "" ? var.origin_fqdn : aws_lb.app.dns_name
}

output "origin_api_domain_name" {
  description = "Hostname the API CloudFront distribution should use as origin"
  value       = var.origin_api_fqdn != "" ? var.origin_api_fqdn : aws_lb.app.dns_name
}

output "origin_https" {
  value = var.origin_fqdn != ""
}

output "instance_role_arn" {
  value = aws_iam_role.app.arn
}

output "app_git_sha_parameter_name" {
  description = "SSM parameter deploy workflows update with github.sha before ASG rolls"
  value       = aws_ssm_parameter.app_git_sha.name
}
