variable "project_name" { type = string }
variable "environment" { type = string }
variable "retention_days" {
  description = "Expire access-log objects after this many days"
  type        = number
  default     = 90
}
variable "tags" {
  type    = map(string)
  default = {}
}
