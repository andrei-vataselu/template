variable "project_name" { type = string }
variable "environment" { type = string }
variable "alb_arn" {
  description = "ALB ARN to associate with this REGIONAL Web ACL"
  type        = string
}
variable "rate_limit" {
  description = "Per-IP rate limit (requests / 5 minutes) matching the CloudFront ACL"
  type        = number
  default     = 2000
}
variable "enable_waf_logging" {
  description = "Send WAF logs to a CloudWatch Logs group (aws-waf-logs-*)"
  type        = bool
  default     = true
}
variable "tags" {
  type    = map(string)
  default = {}
}
