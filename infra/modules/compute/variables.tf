variable "project_name" { type = string }
variable "environment" { type = string }
variable "subnet_ids" {
  description = "Public subnet IDs across >=2 AZs (ALB + ASG)"
  type        = list(string)
}
variable "alb_security_group_id" { type = string }
variable "app_security_group_id" { type = string }
variable "instance_type" {
  type    = string
  default = "t4g.micro"
}
variable "root_volume_gb" {
  type    = number
  default = 30
}
variable "origin_secret_arn" {
  description = "Secrets Manager ARN holding the CloudFront origin verification header value"
  type        = string
}
variable "db_secret_arn" {
  description = "RDS master user secret ARN (AWS-managed). Used to build DATABASE_URL at boot."
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
variable "app_git_url" {
  description = "Optional git URL for full apps (React/Node). Empty uses bootstrap UI."
  type        = string
  default     = ""
}
variable "origin_fqdn" {
  description = "Hostname CloudFront uses for the ALB (e.g. origin-dev.example.com). Empty = ALB DNS + HTTP."
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
variable "tags" {
  type    = map(string)
  default = {}
}
