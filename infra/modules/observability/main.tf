# Guide §15/§16: budgets + SNS alerts (not a hard real-time cap)

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-${var.environment}-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_budgets_budget" "monthly" {
  name              = "${var.project_name}-${var.environment}-monthly"
  budget_type       = "COST"
  limit_amount      = tostring(var.monthly_budget_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-07-01_00:00"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Environment$%s", var.environment)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

resource "aws_ce_anomaly_monitor" "application" {
  count = var.enable_anomaly_detection ? 1 : 0

  name              = "${var.project_name}-${var.environment}"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "application" {
  count = var.enable_anomaly_detection ? 1 : 0

  name      = "${var.project_name}-${var.environment}"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.application[0].arn]

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["10"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  subscriber {
    type    = "EMAIL"
    address = var.alert_email
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/${var.environment}/app"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "web" {
  name              = "/${var.project_name}/${var.environment}/web"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/${var.project_name}/${var.environment}/gateway"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "asg_cpu" {
  alarm_name          = "${var.project_name}-${var.environment}-asg-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "ASG average CPU high — raise asg_desired_capacity manually if sustained (no auto-scale)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.project_name}-${var.environment}-unhealthy-hosts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "ALB has unhealthy API targets — deploy or instance may be failing health checks"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "web_unhealthy_hosts" {
  count = var.enable_web_alarms ? 1 : 0

  alarm_name          = "${var.project_name}-${var.environment}-web-unhealthy-hosts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "ALB has unhealthy frontend targets — deploy or instance may be failing health checks"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.web_target_group_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "web_asg_cpu" {
  count = var.enable_web_alarms ? 1 : 0

  alarm_name          = "${var.project_name}-${var.environment}-web-asg-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Frontend ASG average CPU high — raise web_asg_desired_capacity manually if sustained"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    AutoScalingGroupName = var.web_asg_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2147483648 # 2 GiB — early warning on fixed 20GB volume
  alarm_description   = "RDS free storage low — do not enable autoscaling; expand via Terraform"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  tags = var.tags
}

# Spike in target 4xx often means bad/missing origin secret or probing the ALB.
resource "aws_cloudwatch_metric_alarm" "alb_target_4xx" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-target-4xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_4XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_description   = "Elevated ALB target 4xx (possible origin-secret mismatch or origin probing) — check gateway 403s / rotate status"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_description   = "ALB generating 5xx (often no healthy targets / gateway down) — check ASG + /healthz"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-target-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_description   = "Targets returning 5xx — check API/container logs"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_p95_latency" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-p95-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p95"
  threshold           = 2
  treat_missing_data  = "notBreaching"
  alarm_description   = "ALB target p95 latency > 2s"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU high"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 40
  treat_missing_data  = "notBreaching"
  alarm_description   = "RDS connection count elevated for micro instance"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  tags = var.tags
}

data "aws_region" "current" {}

locals {
  # Both branches must be the same tuple shape (Terraform conditional typing).
  web_host_metrics = var.enable_web_alarms && var.web_target_group_arn_suffix != "" ? [
    ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.web_target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { label = "healthy", color = "#2ca02c" }],
    [".", "UnHealthyHostCount", ".", ".", ".", ".", { label = "unhealthy", color = "#d62728" }],
  ] : [
    ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { label = "web TG n/a", visible = false }],
    ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { label = "web TG n/a", visible = false }],
  ]

  asg_cpu_metrics = concat(
    [
      ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name, { label = "app" }],
    ],
    var.enable_web_alarms && var.web_asg_name != "" ? [
      ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.web_asg_name, { label = "web" }],
    ] : [],
  )

  dashboard_alarm_arns = compact([
    aws_cloudwatch_metric_alarm.asg_cpu.arn,
    aws_cloudwatch_metric_alarm.unhealthy_hosts.arn,
    try(aws_cloudwatch_metric_alarm.web_unhealthy_hosts[0].arn, ""),
    try(aws_cloudwatch_metric_alarm.web_asg_cpu[0].arn, ""),
    aws_cloudwatch_metric_alarm.rds_storage.arn,
    aws_cloudwatch_metric_alarm.alb_target_4xx.arn,
    aws_cloudwatch_metric_alarm.alb_5xx.arn,
    aws_cloudwatch_metric_alarm.alb_target_5xx.arn,
    aws_cloudwatch_metric_alarm.alb_p95_latency.arn,
    aws_cloudwatch_metric_alarm.rds_cpu.arn,
    aws_cloudwatch_metric_alarm.rds_connections.arn,
  ])
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# ${var.project_name} / ${var.environment}\nDefault ops view — ALB, ASG, RDS. Alerts → SNS `${aws_sns_topic.alerts.name}`."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 8
        height = 6
        properties = {
          title   = "ALB request count"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 1
        width  = 8
        height = 6
        properties = {
          title   = "ALB 4xx / 5xx"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", var.alb_arn_suffix, { label = "target 4xx", color = "#ff7f0e" }],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", { label = "target 5xx", color = "#d62728" }],
            [".", "HTTPCode_ELB_5XX_Count", ".", ".", { label = "ELB 5xx", color = "#9467bd" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 1
        width  = 8
        height = 6
        properties = {
          title   = "Target response time"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { label = "avg", stat = "Average" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { label = "p95", stat = "p95" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 8
        height = 6
        properties = {
          title   = "Healthy / unhealthy hosts (API)"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Average"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { label = "healthy", color = "#2ca02c" }],
            [".", "UnHealthyHostCount", ".", ".", ".", ".", { label = "unhealthy", color = "#d62728" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 7
        width  = 8
        height = 6
        properties = {
          title   = "Healthy / unhealthy hosts (web)"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Average"
          metrics = local.web_host_metrics
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 7
        width  = 8
        height = 6
        properties = {
          title   = "ASG CPU"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Average"
          metrics = local.asg_cpu_metrics
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 13
        width  = 12
        height = 6
        properties = {
          title   = "RDS CPU / connections"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id, { label = "CPU %", stat = "Average" }],
            [".", "DatabaseConnections", ".", ".", { label = "connections", stat = "Average", yAxis = "right" }],
          ]
          yAxis = {
            left  = { min = 0, max = 100 }
            right = { min = 0 }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 13
        width  = 12
        height = 6
        properties = {
          title   = "RDS free storage"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Average"
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.db_instance_id, { label = "bytes free" }],
          ]
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 19
        width  = 24
        height = 4
        properties = {
          title  = "Alarms"
          alarms = local.dashboard_alarm_arns
        }
      },
    ]
  })
}
