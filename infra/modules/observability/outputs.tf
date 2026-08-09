output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "budget_name" {
  value = aws_budgets_budget.monthly.name
}

output "app_log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "web_log_group_name" {
  value = aws_cloudwatch_log_group.web.name
}

output "gateway_log_group_name" {
  value = aws_cloudwatch_log_group.gateway.name
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "dashboard_url" {
  value = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
