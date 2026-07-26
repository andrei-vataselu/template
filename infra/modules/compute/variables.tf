variable "project_name" { type = string }
variable "environment" { type = string }
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }
variable "instance_type" {
  type    = string
  default = "t4g.micro"
}
variable "root_volume_gb" {
  type    = number
  default = 20
}
variable "origin_secret_arn" {
  description = "Secrets Manager ARN holding the CloudFront origin verification header value"
  type        = string
}
variable "app_git_url" {
  description = "Optional git URL for full apps (React/Node). Empty uses EC2 Docker bootstrap UI."
  type        = string
  default     = ""
}
variable "origin_fqdn" {
  description = "Hostname CloudFront uses to reach this instance over TLS (e.g. origin-dev.example.com). Empty = plain HTTP origin."
  type        = string
  default     = ""
}
variable "zone_id" {
  description = "Route 53 zone for the certbot DNS-01 challenge. Required when origin_fqdn is set."
  type        = string
  default     = ""
}
variable "certbot_email" {
  description = "Let's Encrypt account email. Required when origin_fqdn is set."
  type        = string
  default     = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}
