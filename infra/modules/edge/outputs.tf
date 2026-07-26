output "distribution_id" {
  value = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  value = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "waf_acl_arn" {
  value = aws_wafv2_web_acl.cloudfront.arn
}

output "site_url" {
  value = length(var.aliases) > 0 ? "https://${var.aliases[0]}" : "https://${aws_cloudfront_distribution.this.domain_name}"
}
