variable "aws_region" {
  description = "Home region (matches the env stacks)"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  type    = string
  default = "popo"
}

variable "application_name" {
  type    = string
  default = "template"
}

variable "domain_name" {
  description = "Registered domain (Route 53 becomes the DNS host; switch nameservers at the registrar). Empty = no zone."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email for root-usage alerts (must confirm both SNS subscriptions)"
  type        = string
}

variable "enable_guardduty" {
  description = "GuardDuty threat detection. ~$1-4/mo at this scale; 30-day free trial shows the exact number"
  type        = bool
  default     = true
}

variable "cloudtrail_retention_days" {
  description = "How long to keep CloudTrail log files in S3"
  type        = number
  default     = 90
}
