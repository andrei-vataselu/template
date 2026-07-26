variable "aws_region" {
  description = "Application region (guide: eu-west-1)"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  type    = string
  default = "popo"
}

variable "application_name" {
  description = "Shared Application tag for Resource Groups / cost filters"
  type        = string
  default     = "template"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "cost_center" {
  type    = string
  default = "cc-dev-sandbox"
}

variable "alert_email" {
  description = "Email for budget/security SNS alerts (must confirm subscription)"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Hard internal monthly budget (alerts only — not a real-time cut-off)"
  type        = number
  default     = 25
}

variable "instance_type" {
  type    = string
  default = "t4g.micro"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

variable "app_git_url" {
  description = "Git URL with apps/ + deploy/ for full Docker stack on EC2"
  type        = string
  default     = ""
}

variable "db_storage_gb" {
  type    = number
  default = 20
}

variable "backup_retention_days" {
  type    = number
  default = 3
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_deletion_protection" {
  type    = bool
  default = false
}

variable "db_skip_final_snapshot" {
  type    = bool
  default = true
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "domain_name" {
  description = "Registered domain hosted in Route 53 by infra/global. Empty = *.cloudfront.net + HTTP origin."
  type        = string
  default     = ""
}

variable "allowed_ip_cidrs" {
  description = "IPv4 CIDRs allowed through CloudFront (WAF). Empty = public. Update when your home/office IP changes."
  type        = list(string)
  default     = []
}
