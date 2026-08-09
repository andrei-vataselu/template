variable "project_name" { type = string }
variable "environment" { type = string }
variable "monthly_budget_usd" {
  type    = number
  default = 25
}
variable "alert_email" { type = string }
variable "enable_anomaly_detection" {
  description = "CE dimensional anomaly monitors are limited per account; disable if quota is exhausted."
  type        = bool
  default     = false
}
variable "asg_name" { type = string }
variable "enable_web_alarms" {
  description = "Create frontend ASG/TG alarms (must be known at plan time — do not derive from ARN suffixes)"
  type        = bool
  default     = true
}

variable "web_asg_name" {
  description = "Frontend ASG name"
  type        = string
  default     = ""
}
variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch dimensions (aws_lb.xxx.arn_suffix)"
  type        = string
}
variable "target_group_arn_suffix" {
  description = "API target group ARN suffix for CloudWatch dimensions"
  type        = string
}
variable "web_target_group_arn_suffix" {
  description = "Frontend target group ARN suffix (empty = no web unhealthy-host alarm)"
  type        = string
  default     = ""
}
variable "db_instance_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
