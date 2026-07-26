variable "project_name" { type = string }
variable "environment" { type = string }
variable "subnet_ids" { type = list(string) }
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

variable "tags" {
  type    = map(string)
  default = {}
}
