variable "project_name" { type = string }
variable "environment" { type = string }
variable "origin_secret_arn" { type = string }
variable "origin_header_name" {
  type    = string
  default = "X-Origin-Verify"
}
variable "site_distribution_id" { type = string }
variable "site_distribution_arn" { type = string }
variable "api_distribution_id" {
  type    = string
  default = ""
}
variable "api_distribution_arn" {
  type    = string
  default = ""
}
variable "alert_topic_arn" { type = string }
variable "app_asg_name" {
  description = "API ASG — SSM sync + rolling refresh after rotation"
  type        = string
}
variable "web_asg_name" {
  description = "Web ASG — SSM sync + rolling refresh after rotation"
  type        = string
}
variable "sync_fallback_wait_seconds" {
  description = "If SSM sync finds no online hosts, wait this long for cron backup before updating CloudFront"
  type        = number
  default     = 90
}
variable "schedule_expression" {
  description = "EventBridge schedule for origin secret rotation"
  type        = string
  default     = "rate(1 day)"
}
variable "tags" {
  type    = map(string)
  default = {}
}
