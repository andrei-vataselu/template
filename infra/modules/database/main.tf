resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-${var.environment}-db"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-db-subnets"
  })
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.project_name}-${var.environment}-pg16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = var.tags
}

resource "aws_db_instance" "this" {
  identifier     = "${var.project_name}-${var.environment}-pg"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage_gb
  # Intentionally omit max_allocated_storage — disables autoscaling (guide §13/§18)
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "app"
  username = "dbadmin"
  port     = 5432

  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period  = var.backup_retention_days
  delete_automated_backups = true
  deletion_protection      = var.deletion_protection
  skip_final_snapshot      = var.skip_final_snapshot
  copy_tags_to_snapshot    = true

  auto_minor_version_upgrade = true
  apply_immediately          = true

  parameter_group_name = aws_db_parameter_group.this.name

  performance_insights_enabled = false

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-pg"
  })
}
