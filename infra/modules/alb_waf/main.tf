# REGIONAL WAF on the ALB — foreign CloudFront still reaches the origin ALB
# (shared CF prefix list), so this ACL is the WAF layer those requests hit.

resource "aws_wafv2_web_acl" "alb" {
  name  = "${var.project_name}-${var.environment}-alb"
  scope = "REGIONAL"

  default_action {
    allow {}
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
      metric_name                = "AlbCommonRuleSet"
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
      metric_name                = "AlbKnownBadInputs"
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
      metric_name                = "AlbIpReputation"
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
      metric_name                = "AlbAnonymousIp"
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
      metric_name                = "AlbSQLi"
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
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AlbRateLimitGlobal"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-${var.environment}-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}

# WAFv2 requires log groups named aws-waf-logs-*
resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_waf_logging ? 1 : 0

  name              = "aws-waf-logs-${var.project_name}-${var.environment}-alb"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  count = var.enable_waf_logging ? 1 : 0

  policy_name = "${var.project_name}-${var.environment}-alb-waf-logs"
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

resource "aws_wafv2_web_acl_logging_configuration" "alb" {
  count = var.enable_waf_logging ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.alb.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}
