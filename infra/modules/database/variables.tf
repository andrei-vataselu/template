variable "project_name" { type = string }
variable "environment" { type = string }
variable "vpc_id" {
  description = "VPC for the ensure-app Lambda ENIs"
  type        = string
}
variable "subnet_ids" {
  description = "Private DB subnet IDs for the RDS subnet group"
  type        = list(string)
}
variable "lambda_subnet_ids" {
  description = "Private app subnet IDs (NAT egress) for the ensure-app Lambda"
  type        = list(string)
}
variable "security_group_id" { type = string }
variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}
variable "allocated_storage_gb" {
  type    = number
  default = 20
}
variable "backup_retention_days" {
  type    = number
  default = 3
}

variable "multi_az" {
  description = "Prod typically true; same networking either way"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  type    = bool
  default = true
}

variable "secret_recovery_window_in_days" {
  description = "Secrets Manager recovery window for the app DB secret (0 = force delete; prod typically 7)."
  type        = number
  default     = 0
}

variable "tags" {
  type    = map(string)
  default = {}
}
