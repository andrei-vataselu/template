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
  description = "Force TOTP MFA for all users"
  type        = bool
  default     = false
}
variable "allow_self_signup" {
  description = "Allow public SignUp (email verification still required)"
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
  description = "Route 53 zone for custom auth domain + SES DNS. Required when custom_auth_domain or ses_email_domain is set."
  type        = string
  default     = ""
}
variable "ses_email_domain" {
  description = "Verified SES domain used to send Cognito emails (e.g. example.com). Empty = Cognito default mail."
  type        = string
  default     = ""
}
variable "from_email_address" {
  description = "From address for Cognito mail, e.g. noreply@example.com"
  type        = string
  default     = ""
}
variable "reply_to_email_address" {
  description = "Reply-To for Cognito mail (also SES-verified in sandbox)"
  type        = string
  default     = ""
}
variable "ses_cognito_mail_enabled" {
  description = "Send Cognito mail via SES (noreploy@domain). Requires SES production access (sandbox can only mail verified recipients)."
  type        = bool
  default     = false
}
variable "tags" {
  type    = map(string)
  default = {}
}
