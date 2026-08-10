terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

# Viewer certificate for the custom domain (CloudFront requires us-east-1)
resource "aws_acm_certificate" "site" {
  count    = length(var.aliases) > 0 ? 1 : 0
  provider = aws.us_east_1

  domain_name               = var.aliases[0]
  subject_alternative_names = slice(var.aliases, 1, length(var.aliases))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_route53_record" "site_cert_validation" {
  for_each = length(var.aliases) > 0 ? toset(var.aliases) : toset([])

  zone_id = var.zone_id
  name = one([
    for dvo in aws_acm_certificate.site[0].domain_validation_options : dvo.resource_record_name
    if dvo.domain_name == each.key
  ])
  type = one([
    for dvo in aws_acm_certificate.site[0].domain_validation_options : dvo.resource_record_type
    if dvo.domain_name == each.key
  ])
  records = [one([
    for dvo in aws_acm_certificate.site[0].domain_validation_options : dvo.resource_record_value
    if dvo.domain_name == each.key
  ])]
  ttl             = 300
  allow_overwrite = true
}

# Waits until DNS validation succeeds — the registrar's nameservers must
# already point at the Route 53 zone or this will time out (~75 min)
resource "aws_acm_certificate_validation" "site" {
  count    = length(var.aliases) > 0 ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.site_cert_validation : r.fqdn]
}

# Optional IP allowlist — when set, only these IPs can reach the site
resource "aws_wafv2_ip_set" "allowlist" {
  count    = length(var.allowed_ip_cidrs) > 0 ? 1 : 0
  provider = aws.us_east_1

  name               = "${var.project_name}-${var.environment}-allowlist"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = var.allowed_ip_cidrs
  tags               = var.tags
}

# WAF for CloudFront MUST live in us-east-1
resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.us_east_1

  name  = "${var.project_name}-${var.environment}-cf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Evaluated first: block everyone not on the allowlist.
  # Managed rules below still inspect the traffic that gets through.
  dynamic "rule" {
    for_each = length(var.allowed_ip_cidrs) > 0 ? [1] : []

    content {
      name     = "IPAllowlistOnly"
      priority = 0

      action {
        block {}
      }

      statement {
        not_statement {
          statement {
            ip_set_reference_statement {
              arn = aws_wafv2_ip_set.allowlist[0].arn
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "IPAllowlistOnly"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "IpReputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAnonymousIpList"
    priority = 40

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAnonymousIpList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AnonymousIp"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 50

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLi"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitGlobal"
    priority = 100

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitGlobal"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-${var.environment}-cf-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# CloudFront WAF logs must live in us-east-1 (same region as the ACL)
resource "aws_cloudwatch_log_group" "waf" {
  count    = var.enable_waf_logging ? 1 : 0
  provider = aws.us_east_1

  name              = "aws-waf-logs-${var.project_name}-${var.environment}-cf"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  count    = var.enable_waf_logging ? 1 : 0
  provider = aws.us_east_1

  policy_name = "${var.project_name}-${var.environment}-cf-waf-logs"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AWSLogDeliveryWrite"
      Effect = "Allow"
      Principal = {
        Service = "delivery.logs.amazonaws.com"
      }
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "${aws_cloudwatch_log_group.waf[0].arn}:*"
    }]
  })
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
  count    = var.enable_waf_logging ? 1 : 0
  provider = aws.us_east_1

  resource_arn            = aws_wafv2_web_acl.cloudfront.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  provider = aws.us_east_1
  name     = "Managed-CachingDisabled"
}

resource "aws_cloudfront_cache_policy" "static" {
  provider = aws.us_east_1

  name        = "${var.project_name}-${var.environment}-static"
  default_ttl = 86400
  max_ttl     = 604800
  min_ttl     = 60

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

# API uses Managed-CachingDisabled (custom TTL=0 policies reject encoding/header settings).

resource "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  provider = aws.us_east_1

  name = "${var.project_name}-${var.environment}-origin-req"

  cookies_config {
    cookie_behavior = "all"
  }
  # Forward all viewer headers except Host — ALB/ACM need Host = origin hostname
  headers_config {
    header_behavior = "allExcept"
    headers {
      items = ["Host"]
    }
  }
  query_strings_config {
    query_string_behavior = "all"
  }
}

resource "aws_cloudfront_response_headers_policy" "security" {
  provider = aws.us_east_1

  name = "${var.project_name}-${var.environment}-security-headers"

  security_headers_config {
    # XSS blast-radius control for the SPA (tokens live in sessionStorage)
    dynamic "content_security_policy" {
      for_each = var.content_security_policy != "" ? [1] : []
      content {
        content_security_policy = var.content_security_policy
        override                = true
      }
    }

    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "geolocation=(), microphone=(), camera=()"
      override = true
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  provider = aws.us_east_1

  enabled = true
  # The allowlist ipset is IPv4-only; keep IPv6 off while it's active so
  # nobody (including you on an IPv6 connection) slips past or gets confused
  is_ipv6_enabled = length(var.allowed_ip_cidrs) == 0
  comment         = "${var.project_name}-${var.environment}"
  price_class     = var.price_class
  web_acl_id      = aws_wafv2_web_acl.cloudfront.arn
  http_version    = "http2and3"
  aliases         = var.aliases

  dynamic "logging_config" {
    for_each = var.access_logs_bucket != "" ? [1] : []
    content {
      include_cookies = false
      bucket          = var.access_logs_bucket_domain_name
      prefix          = "${var.access_logs_prefix}/site"
    }
  }

  origin {
    domain_name = var.origin_domain_name
    origin_id   = "ec2-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = var.origin_https ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = var.origin_header_name
      value = var.origin_header_value
    }
  }

  default_cache_behavior {
    target_origin_id       = "ec2-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id   = aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  ordered_cache_behavior {
    path_pattern           = "/assets/*"
    target_origin_id       = "ec2-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = aws_cloudfront_cache_policy.static.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Custom-domain cert when aliases are set, otherwise the *.cloudfront.net default
  dynamic "viewer_certificate" {
    for_each = length(var.aliases) > 0 ? [1] : []

    content {
      acm_certificate_arn      = aws_acm_certificate_validation.site[0].certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  dynamic "viewer_certificate" {
    for_each = length(var.aliases) > 0 ? [] : [1]

    content {
      cloudfront_default_certificate = true
      minimum_protocol_version       = "TLSv1.2_2021"
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# API distribution (api-dev / api hostname). Reuses the WAF ACL, origin
# request policy, and response headers policy above — CloudFront itself has
# no fixed monthly cost, so this keeps the split within the same budget.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "api" {
  count    = length(var.api_aliases) > 0 ? 1 : 0
  provider = aws.us_east_1

  domain_name               = var.api_aliases[0]
  subject_alternative_names = slice(var.api_aliases, 1, length(var.api_aliases))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_route53_record" "api_cert_validation" {
  for_each = length(var.api_aliases) > 0 ? toset(var.api_aliases) : toset([])

  zone_id = var.zone_id
  name = one([
    for dvo in aws_acm_certificate.api[0].domain_validation_options : dvo.resource_record_name
    if dvo.domain_name == each.key
  ])
  type = one([
    for dvo in aws_acm_certificate.api[0].domain_validation_options : dvo.resource_record_type
    if dvo.domain_name == each.key
  ])
  records = [one([
    for dvo in aws_acm_certificate.api[0].domain_validation_options : dvo.resource_record_value
    if dvo.domain_name == each.key
  ])]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "api" {
  count    = length(var.api_aliases) > 0 ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.api[0].arn
  validation_record_fqdns = [for r in aws_route53_record.api_cert_validation : r.fqdn]
}

resource "aws_cloudfront_distribution" "api" {
  count    = length(var.api_aliases) > 0 ? 1 : 0
  provider = aws.us_east_1

  enabled         = true
  is_ipv6_enabled = length(var.allowed_ip_cidrs) == 0
  comment         = "${var.project_name}-${var.environment}-api"
  price_class     = var.price_class
  web_acl_id      = aws_wafv2_web_acl.cloudfront.arn
  http_version    = "http2and3"
  aliases         = var.api_aliases

  dynamic "logging_config" {
    for_each = var.access_logs_bucket != "" ? [1] : []
    content {
      include_cookies = false
      bucket          = var.access_logs_bucket_domain_name
      prefix          = "${var.access_logs_prefix}/api"
    }
  }

  origin {
    domain_name = var.api_origin_domain_name
    origin_id   = "api-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = var.origin_https ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = var.origin_header_name
      value = var.origin_header_value
    }
  }

  # API responses are never cached; all viewer headers (Authorization,
  # Origin for CORS preflights) are forwarded except Host
  default_cache_behavior {
    target_origin_id       = "api-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id   = aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.api[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = var.tags
}

resource "aws_route53_record" "api_a" {
  for_each = toset(var.api_aliases)

  zone_id = var.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.api[0].domain_name
    zone_id                = aws_cloudfront_distribution.api[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api_aaaa" {
  for_each = length(var.allowed_ip_cidrs) == 0 ? toset(var.api_aliases) : toset([])

  zone_id = var.zone_id
  name    = each.value
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.api[0].domain_name
    zone_id                = aws_cloudfront_distribution.api[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# Point the alias hostnames at the distribution
resource "aws_route53_record" "site_a" {
  for_each = toset(var.aliases)

  zone_id         = var.zone_id
  name            = each.value
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "site_aaaa" {
  # Only when IPv6 is on (it's off while the IP allowlist is active)
  for_each = length(var.allowed_ip_cidrs) == 0 ? toset(var.aliases) : toset([])

  zone_id = var.zone_id
  name    = each.value
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
