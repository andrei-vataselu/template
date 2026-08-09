variable "project_name" { type = string }
variable "environment" { type = string }
variable "callback_urls" {
  type    = list(string)
  default = ["https://localhost/callback"]
}
variable "logout_urls" {
  type    = list(string)
  default = ["https://localhost/logout"]
}
variable "require_mfa" {
  description = "Force TOTP MFA for all users (pool is invite-only)"
  type        = bool
  default     = true
}
variable "deletion_protection" {
  description = "Protect the user pool from deletion (enable in prod)"
  type        = bool
  default     = false
}
variable "custom_auth_domain" {
  description = "FQDN for Hosted UI (e.g. auth.dev.example.com). Empty uses a Cognito prefix domain."
  type        = string
  default     = ""
}
variable "zone_id" {
  description = "Route 53 zone for custom auth domain ACM validation + alias. Required when custom_auth_domain is set."
  type        = string
  default     = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}
