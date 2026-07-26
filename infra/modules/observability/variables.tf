variable "project_name" { type = string }
variable "environment" { type = string }
variable "monthly_budget_usd" {
  type    = number
  default = 25
}
variable "alert_email" { type = string }
variable "ec2_instance_id" { type = string }
variable "db_instance_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
