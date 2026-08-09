variable "project_name" { type = string }
variable "environment" { type = string }
variable "origin_domain_name" { type = string }
variable "origin_header_name" { type = string }
variable "origin_header_value" {
  type      = string
  sensitive = true
}
variable "price_class" {
  type    = string
  default = "PriceClass_100"
}
variable "aliases" {
  description = "Custom domain aliases (first entry is the certificate CN). Empty = *.cloudfront.net default cert."
  type        = list(string)
  default     = []
}
variable "zone_id" {
  description = "Route 53 hosted zone for cert validation + alias records. Required when aliases is set."
  type        = string
  default     = ""
}
variable "origin_https" {
  description = "true = https-only to the origin (requires a valid cert on the instance for the origin hostname)"
  type        = bool
  default     = false
}
variable "api_aliases" {
  description = "API hostnames (e.g. api-dev.example.com). Non-empty creates a second distribution for the API that shares the WAF ACL (no extra fixed cost)."
  type        = list(string)
  default     = []
}
variable "api_origin_domain_name" {
  description = "Origin hostname for the API distribution (e.g. origin-api-dev.example.com). Required when api_aliases is set."
  type        = string
  default     = ""
}
variable "content_security_policy" {
  description = "Content-Security-Policy header value added at the edge (empty = header not set). Limits XSS blast radius for the SPA."
  type        = string
  default     = ""
}
variable "allowed_ip_cidrs" {
  description = "IPv4 CIDRs allowed to reach the distribution. Empty = open to everyone. When set, WAF blocks all other IPs and IPv6 is disabled on the distribution."
  type        = list(string)
  default     = []
}
variable "access_logs_bucket" {
  description = "S3 bucket name for CloudFront standard logs (empty = disabled)"
  type        = string
  default     = ""
}
variable "access_logs_bucket_domain_name" {
  description = "S3 bucket regional/domain name required by CloudFront logging_config.bucket"
  type        = string
  default     = ""
}
variable "access_logs_prefix" {
  description = "S3 key prefix for CloudFront standard logs"
  type        = string
  default     = "cloudfront"
}
variable "enable_waf_logging" {
  description = "Send CloudFront WAF logs to CloudWatch Logs in us-east-1"
  type        = bool
  default     = true
}
variable "tags" {
  type    = map(string)
  default = {}
}
