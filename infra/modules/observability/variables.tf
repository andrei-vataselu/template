variable "project_name" { type = string }
variable "environment" { type = string }
variable "monthly_budget_usd" {
  type    = number
  default = 25
}
variable "alert_email" { type = string }
variable "asg_name" { type = string }
variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch dimensions (aws_lb.xxx.arn_suffix)"
  type        = string
}
variable "target_group_arn_suffix" {
  description = "Target group ARN suffix for CloudWatch dimensions"
  type        = string
}
variable "db_instance_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
