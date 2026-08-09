terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

data "archive_file" "rotate" {
  type        = "zip"
  output_path = "${path.module}/rotate.zip"
  source {
    content  = file("${path.module}/rotate.py")
    filename = "rotate.py"
  }
}

resource "aws_iam_role" "rotate" {
  name = "${var.project_name}-${var.environment}-origin-rotate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rotate_basic" {
  role       = aws_iam_role.rotate.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "rotate" {
  name = "${var.project_name}-${var.environment}-origin-rotate"
  role = aws_iam_role.rotate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Secret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [var.origin_secret_arn]
      },
      {
        Sid    = "CloudFront"
        Effect = "Allow"
        Action = [
          "cloudfront:GetDistribution",
          "cloudfront:GetDistributionConfig",
          "cloudfront:UpdateDistribution",
        ]
        Resource = compact([
          var.site_distribution_arn,
          var.api_distribution_arn != "" ? var.api_distribution_arn : null,
        ])
      },
      {
        Sid    = "AsgDescribe"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeInstanceRefreshes",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "AsgRefreshNamed"
        Effect = "Allow"
        Action = ["autoscaling:StartInstanceRefresh"]
        Resource = [
          "arn:aws:autoscaling:*:*:autoScalingGroup:*:autoScalingGroupName/${var.app_asg_name}",
          "arn:aws:autoscaling:*:*:autoScalingGroup:*:autoScalingGroupName/${var.web_asg_name}",
        ]
      },
      {
        Sid      = "SsmSendCommand"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = ["arn:aws:ssm:*::document/AWS-RunShellScript"]
      },
      {
        Sid      = "SsmSendToTaggedInstances"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = ["arn:aws:ec2:*:*:instance/*"]
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Application" = lookup(var.tags, "Application", var.project_name)
            "ssm:resourceTag/Environment" = var.environment
          }
        }
      },
      {
        Sid    = "SsmRead"
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation",
        ]
        Resource = ["*"]
      },
      {
        Sid      = "Sns"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [var.alert_topic_arn]
      }
    ]
  })
}

resource "aws_lambda_function" "rotate" {
  function_name = "${var.project_name}-${var.environment}-origin-rotate"
  role          = aws_iam_role.rotate.arn
  handler       = "rotate.handler"
  runtime       = "python3.12"
  # SSM sync + optional fallback wait + CF updates
  timeout       = 300
  memory_size   = 256
  architectures = ["arm64"]

  filename         = data.archive_file.rotate.output_path
  source_code_hash = data.archive_file.rotate.output_base64sha256

  environment {
    variables = {
      ORIGIN_SECRET_ARN          = var.origin_secret_arn
      ORIGIN_HEADER_NAME         = var.origin_header_name
      SITE_DISTRIBUTION_ID       = var.site_distribution_id
      API_DISTRIBUTION_ID        = var.api_distribution_id
      ALERT_TOPIC_ARN            = var.alert_topic_arn
      APP_ASG_NAME               = var.app_asg_name
      WEB_ASG_NAME               = var.web_asg_name
      SYNC_FALLBACK_WAIT_SECONDS = tostring(var.sync_fallback_wait_seconds)
      APP_LABEL                  = "${var.project_name}-${var.environment}"
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-origin-rotate"
  })

  depends_on = [
    aws_iam_role_policy_attachment.rotate_basic,
    aws_iam_role_policy.rotate,
  ]
}

resource "aws_cloudwatch_log_group" "rotate" {
  name              = "/aws/lambda/${aws_lambda_function.rotate.function_name}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_event_rule" "weekly" {
  name                = "${var.project_name}-${var.environment}-origin-rotate"
  description         = "Fully automated origin secret rotation (SM → SSM sync → CF → clear previous → ASG refresh)"
  schedule_expression = var.schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "weekly" {
  rule      = aws_cloudwatch_event_rule.weekly.name
  target_id = "origin-rotate"
  arn       = aws_lambda_function.rotate.arn
}

resource "aws_lambda_permission" "weekly" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotate.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly.arn
}
