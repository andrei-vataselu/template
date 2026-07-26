# Lower-cost compromise (guide §1): EC2 may be public but ingress only from CloudFront.
# Rules are standalone resources so the app and db SGs can reference each other
# without a Terraform dependency cycle.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-${var.environment}-app"
  description = "App origin - CloudFront prefix list only; no SSH/RDP"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-app-sg"
  })
}

resource "aws_security_group" "db" {
  name        = "${var.project_name}-${var.environment}-db"
  description = "PostgreSQL only from application SG; no egress"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-db-sg"
  })
}

# --- App ingress ---

resource "aws_vpc_security_group_ingress_rule" "app_http_from_cloudfront" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP from CloudFront edge only"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_ingress_rule" "app_https_from_cloudfront" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS from CloudFront edge only (https-only origin)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

# --- App egress (least privilege: SSM/updates/git + DB) ---

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS for SSM, dnf, Docker Hub, git (no NAT; public subnet)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# VPC-internal only: the Route 53 Resolver (VPC+2) bypasses SG filtering anyway,
# so this rule exists purely to stop DNS exfiltration to external resolvers
resource "aws_vpc_security_group_egress_rule" "app_dns_out" {
  security_group_id = aws_security_group.app.id
  description       = "DNS to VPC resolver only (blocks DNS exfiltration)"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "app_postgres_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to database SG"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.db.id
}

# --- DB ingress (no egress rules at all: stateful responses still flow) ---

resource "aws_vpc_security_group_ingress_rule" "db_postgres_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from application SG only"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app.id
}
