variable "project_name" { type = string }
variable "environment" { type = string }
variable "vpc_id" {
  description = "VPC for ALB target group (pass explicitly — subnet data lookups can defer and force TG replace)"
  type        = string
}
variable "alb_subnet_ids" {
  description = "Public subnet IDs across >=2 AZs for the internet-facing ALB"
  type        = list(string)
}
variable "app_subnet_ids" {
  description = "Private app subnet IDs across >=2 AZs for ASG instances (egress via NAT)"
  type        = list(string)
}
variable "alb_security_group_id" { type = string }
variable "app_security_group_id" { type = string }
variable "web_security_group_id" {
  description = "SG for frontend instances (no DB egress). Empty = fall back to app SG."
  type        = string
  default     = ""
}
variable "instance_type" {
  description = "API (backend) instance type"
  type        = string
  default     = "t4g.micro"
}
variable "web_instance_type" {
  description = "Frontend instance type — static nginx needs very little, keep costs flat"
  type        = string
  default     = "t4g.nano"
}
variable "root_volume_gb" {
  description = "API instance root volume"
  type        = number
  default     = 30
}
variable "web_root_volume_gb" {
  description = "Frontend instance root volume (static site build needs less)"
  type        = number
  default     = 20
}
variable "origin_secret_arn" {
  description = "Secrets Manager ARN holding the CloudFront origin verification header value"
  type        = string
}
variable "db_app_secret_arn" {
  description = "Secrets Manager ARN for the least-privilege app DB user (runtime DATABASE_URL)"
  type        = string
  sensitive   = true
}
variable "db_host" {
  description = "RDS hostname (managed secrets often omit host — only username/password)."
  type        = string
}
variable "db_port" {
  type    = number
  default = 5432
}
variable "db_name" {
  type    = string
  default = "app"
}
variable "cognito_region" {
  type = string
}
variable "cognito_user_pool_id" {
  type = string
}
variable "cognito_user_pool_arn" {
  type = string
}
variable "cognito_spa_client_id" {
  type = string
}
variable "cognito_hosted_ui_domain" {
  description = "Cognito domain prefix (not full URL), e.g. popo-dev-a1b2c3"
  type        = string
}
variable "bootstrap_admin_emails" {
  description = "Comma-separated emails that receive admin RBAC on first sign-in (matched via Cognito, never stored)"
  type        = string
  default     = ""
}
variable "invite_only" {
  description = "When true, API rejects Cognito users with no local directory row (must be invited first)."
  type        = bool
  default     = true
}
variable "app_git_url" {
  description = "Optional git URL for full apps (React/Node). Empty uses bootstrap UI."
  type        = string
  default     = ""
}

variable "app_git_sha" {
  description = <<-EOT
    Optional git commit SHA to pin at first boot (SSM /{project}/{env}/app-git-sha).
    Empty/"unpinned" = shallow clone of default branch tip.
    Deploy workflows overwrite the SSM parameter with github.sha before ASG rolls —
    keep this empty in tfvars unless seeding a known pin; terraform ignores later value drift.
  EOT
  type        = string
  default     = ""
}
variable "origin_fqdn" {
  description = "Hostname CloudFront uses for the ALB (e.g. origin-dev.example.com). Empty = ALB DNS + HTTP."
  type        = string
  default     = ""
}
variable "origin_api_fqdn" {
  description = "API origin hostname on the same ALB (e.g. origin-api-dev.example.com). Requires origin_fqdn. Empty = path-based /api routing only."
  type        = string
  default     = ""
}
variable "allowed_origins" {
  description = "Comma-separated browser origins allowed by API CORS (e.g. https://dev.example.com). Empty disables CORS middleware."
  type        = string
  default     = ""
}
variable "api_base_url" {
  description = "Absolute API base URL baked into the frontend build (e.g. https://api-dev.example.com). Empty = same-origin /api."
  type        = string
  default     = ""
}
variable "zone_id" {
  description = "Route 53 zone for origin ACM validation + alias. Required when origin_fqdn is set."
  type        = string
  default     = ""
}
variable "asg_min_size" {
  description = "Minimum instances (keep 1 for predictable cost)"
  type        = number
  default     = 1
}
variable "asg_desired_capacity" {
  description = "Steady-state instance count. Raise manually to scale; no CPU autoscaling by default."
  type        = number
  default     = 1
}
variable "asg_max_size" {
  description = "Hard cap. Must be >= desired+1 for zero-downtime rolling deploys (instance refresh)."
  type        = number
  default     = 2
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
  description = "Optional AMI ID pin for launch templates. Empty = latest AL2023 ARM64 from SSM."
  type        = string
  default     = ""
}
variable "access_logs_bucket" {
  description = "S3 bucket for ALB access logs (empty = disabled)"
  type        = string
  default     = ""
}

variable "access_logs_prefix" {
  description = "S3 key prefix for ALB access logs"
  type        = string
  default     = "alb"
}

variable "tags" {
  type    = map(string)
  default = {}
}
