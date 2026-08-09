# VPC Lambda provisions the least-privilege DB role so EC2 never needs the master secret.

data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_security_group" "ensure_app" {
  name        = "${var.project_name}-${var.environment}-db-ensure"
  description = "Lambda that creates/updates the app DB role (master access only here)"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-db-ensure-sg"
  })
}

resource "aws_vpc_security_group_egress_rule" "ensure_app_https" {
  security_group_id = aws_security_group.ensure_app.id
  description       = "Secrets Manager + RDS CA download via NAT"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ensure_app_dns" {
  security_group_id = aws_security_group.ensure_app.id
  description       = "DNS to VPC resolver"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "ensure_app_postgres" {
  security_group_id            = aws_security_group.ensure_app.id
  description                  = "PostgreSQL to database"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_ensure_app" {
  security_group_id            = var.security_group_id
  description                  = "PostgreSQL from ensure-app Lambda"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.ensure_app.id
}

resource "aws_iam_role" "ensure_app" {
  name = "${var.project_name}-${var.environment}-db-ensure"

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

resource "aws_iam_role_policy_attachment" "ensure_app_basic" {
  role       = aws_iam_role.ensure_app.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "ensure_app_vpc" {
  role       = aws_iam_role.ensure_app.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "ensure_app_secrets" {
  name = "${var.project_name}-${var.environment}-db-ensure-secrets"
  role = aws_iam_role.ensure_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadMasterAndAppSecrets"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = [
        aws_db_instance.this.master_user_secret[0].secret_arn,
        aws_secretsmanager_secret.app.arn,
      ]
    }]
  })
}

data "archive_file" "ensure_app" {
  type        = "zip"
  source_dir  = "${path.module}/ensure_app"
  output_path = "${path.module}/ensure_app.zip"
  excludes    = ["__pycache__", "*.pyc"]
}

resource "aws_lambda_function" "ensure_app" {
  function_name = "${var.project_name}-${var.environment}-db-ensure-app"
  role          = aws_iam_role.ensure_app.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 256
  architectures = ["arm64"]

  filename         = data.archive_file.ensure_app.output_path
  source_code_hash = data.archive_file.ensure_app.output_base64sha256

  vpc_config {
    subnet_ids         = var.lambda_subnet_ids
    security_group_ids = [aws_security_group.ensure_app.id]
  }

  environment {
    variables = {
      APP_ENV = var.environment
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-db-ensure-app"
  })

  depends_on = [
    aws_iam_role_policy_attachment.ensure_app_basic,
    aws_iam_role_policy_attachment.ensure_app_vpc,
    aws_iam_role_policy.ensure_app_secrets,
  ]
}

resource "aws_cloudwatch_log_group" "ensure_app" {
  name              = "/aws/lambda/${aws_lambda_function.ensure_app.function_name}"
  retention_in_days = 14
  tags              = var.tags
}

# Re-run when the app password or DB endpoint changes (Terraform apply / password rotate).
resource "aws_lambda_invocation" "ensure_app" {
  function_name = aws_lambda_function.ensure_app.function_name
  input = jsonencode({
    master_secret_arn = aws_db_instance.this.master_user_secret[0].secret_arn
    app_secret_arn    = aws_secretsmanager_secret.app.arn
    # Force replace when credentials or host change
    app_version = aws_secretsmanager_secret_version.app.version_id
    db_address  = aws_db_instance.this.address
  })

  depends_on = [
    aws_db_instance.this,
    aws_secretsmanager_secret_version.app,
    aws_vpc_security_group_ingress_rule.db_from_ensure_app,
    aws_cloudwatch_log_group.ensure_app,
  ]

  lifecycle {
    replace_triggered_by = [
      aws_secretsmanager_secret_version.app.version_id,
      aws_db_instance.this.address,
      aws_lambda_function.ensure_app.source_code_hash,
    ]
  }
}
