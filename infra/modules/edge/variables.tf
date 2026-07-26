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
variable "allowed_ip_cidrs" {
  description = "IPv4 CIDRs allowed to reach the distribution. Empty = open to everyone. When set, WAF blocks all other IPs and IPv6 is disabled on the distribution."
  type        = list(string)
  default     = []
}
variable "tags" {
  type    = map(string)
  default = {}
}
