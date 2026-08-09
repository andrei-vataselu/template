# REGIONAL WAF for Cognito Hosted UI (auth.*). Distinct from the CloudFront ACL in us-east-1.
# Cognito custom domains terminate on AWS-managed CloudFront with IPv6 enabled, so an
# IPv4-only allowlist blocks real browsers that prefer AAAA — keep IPv4 + IPv6 in sync.

locals {
  cognito_waf_has_v4       = length(var.allowed_ip_cidrs) > 0
  cognito_waf_has_v6       = length(var.allowed_ipv6_cidrs) > 0
  cognito_waf_ip_allowlist = local.cognito_waf_has_v4 || local.cognito_waf_has_v6
  # or_statement needs ≥2 children — duplicate the sole ARN when only one family is set.
  cognito_waf_allow_arns = concat(
    local.cognito_waf_has_v4 ? [aws_wafv2_ip_set.allowlist[0].arn] : [],
    local.cognito_waf_has_v6 ? [aws_wafv2_ip_set.allowlist_v6[0].arn] : [],
  )
  cognito_waf_allow_arns_or = length(local.cognito_waf_allow_arns) == 1 ? [
    local.cognito_waf_allow_arns[0],
    local.cognito_waf_allow_arns[0],
  ] : local.cognito_waf_allow_arns
}

resource "aws_wafv2_ip_set" "allowlist" {
  count = local.cognito_waf_has_v4 ? 1 : 0

  name               = "${var.project_name}-${var.environment}-cognito-allowlist"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.allowed_ip_cidrs
  tags               = var.tags
}

resource "aws_wafv2_ip_set" "allowlist_v6" {
  count = local.cognito_waf_has_v6 ? 1 : 0

  name               = "${var.project_name}-${var.environment}-cognito-allowlist-v6"
  scope              = "REGIONAL"
  ip_address_version = "IPV6"
  addresses          = var.allowed_ipv6_cidrs
  tags               = var.tags
}

resource "aws_wafv2_web_acl" "cognito" {
  name  = "${var.project_name}-${var.environment}-cognito"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.cognito_waf_ip_allowlist ? [1] : []

    content {
      name     = "IPAllowlistOnly"
      priority = 0

      action {
        block {}
      }

      statement {
        not_statement {
          statement {
            # Match if client IP is in either allowlist (WAF IP sets are v4-xor-v6).
            or_statement {
              dynamic "statement" {
                for_each = local.cognito_waf_allow_arns_or
                content {
                  ip_set_reference_statement {
                    arn = statement.value
                  }
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "CognitoIPAllowlistOnly"
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
      metric_name                = "CognitoCommonRuleSet"
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
      metric_name                = "CognitoKnownBadInputs"
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
      metric_name                = "CognitoIpReputation"
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
      metric_name                = "CognitoAnonymousIp"
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
      metric_name                = "CognitoSQLi"
      sampled_requests_enabled   = true
    }
  }

  # Tighter than the site/API CF ACL — Hosted UI is login/recovery only
  rule {
    name     = "RateLimitAuth"
    priority = 100

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 300
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CognitoRateLimitAuth"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-${var.environment}-cognito-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_association" "cognito" {
  resource_arn = aws_cognito_user_pool.this.arn
  web_acl_arn  = aws_wafv2_web_acl.cognito.arn
}
