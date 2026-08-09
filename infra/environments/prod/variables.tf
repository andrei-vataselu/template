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
  default = "prod"
}

variable "cost_center" {
  type    = string
  default = "cc-prod-core"
}

variable "alert_email" {
  description = "Email for budget/security SNS alerts (must confirm subscription)"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Hard internal monthly budget (alerts only — not a real-time cut-off)"
  type        = number
  default     = 140
}

variable "instance_type" {
  description = "Backend (API) instance type"
  type        = string
  default     = "t4g.small"
}

variable "web_instance_type" {
  description = "Frontend instance type (static nginx needs little; keeps the split near cost-neutral)"
  type        = string
  default     = "t4g.micro"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "root_volume_gb" {
  type    = number
  default = 40
}

variable "app_git_url" {
  description = "Git URL with apps/ + deploy/ for full Docker stack on EC2"
  type        = string
  default     = ""
}

variable "app_git_sha" {
  description = "Optional commit SHA seed for SSM /{project}/{env}/app-git-sha (empty = unpinned until deploy writes github.sha)"
  type        = string
  default     = ""
}

variable "db_storage_gb" {
  type    = number
  default = 20
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "db_multi_az" {
  type    = bool
  default = false
}

# Safe-by-default for production data: protect against accidental
# `terraform destroy` and always keep a final snapshot
variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "db_skip_final_snapshot" {
  type    = bool
  default = false
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
  description = "IPv4 CIDRs allowed through CloudFront (WAF). Empty = public (normal for prod)."
  type        = list(string)
  default     = []
}

variable "allowed_ipv6_cidrs" {
  description = "IPv6 CIDRs allowed through Cognito Hosted UI WAF. Needed when auth.* is dual-stack and browsers prefer IPv6."
  type        = list(string)
  default     = []
}

variable "asg_min_size" {
  type    = number
  default = 1
}

variable "asg_desired_capacity" {
  description = "Steady-state instances. Raise to scale; no CPU autoscaling (predictable cost)."
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Hard cap. Keep >= desired+1 so rolling deploys can launch a replacement first."
  type        = number
  default     = 3
}

variable "web_asg_min_size" {
  type    = number
  default = 1
}

variable "web_asg_desired_capacity" {
  type    = number
  default = 1
}

variable "web_asg_max_size" {
  description = "Hard cap for frontend instances. Keep >= desired+1 for rolling deploys."
  type        = number
  default     = 2
}

variable "ami_id" {
  description = "Optional AMI ID pin for ASG launch templates. Empty = latest AL2023 ARM64 from SSM."
  type        = string
  default     = ""
}
