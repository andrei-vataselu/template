# CloudFront → ALB → EC2. App instances only accept traffic from the ALB.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb"
  description = "ALB - CloudFront prefix list only; no SSH/RDP"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  })
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-${var.environment}-app"
  description = "API instances - ALB only; no SSH/RDP"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-app-sg"
  })
}

# Frontend instances get their own SG: same ALB-only ingress but NO database
# egress — a compromised web box cannot even open a TCP connection to RDS.
resource "aws_security_group" "web" {
  name        = "${var.project_name}-${var.environment}-web"
  description = "Web (frontend) instances - ALB only; no SSH/RDP; no DB access"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-web-sg"
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

# --- ALB ingress (CloudFront edge only) ---
# CloudFront managed prefix list uses ~55 rule slots. Default SG quota is 60,
# so only ONE PL-backed rule fits (HTTPS). HTTP is unused when origin is https-only.

resource "aws_vpc_security_group_ingress_rule" "alb_https_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from CloudFront edge only"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to API instances"
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to web instances"
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.web.id
}

# --- App ingress (ALB only) ---

resource "aws_vpc_security_group_ingress_rule" "app_http_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from ALB only"
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

# --- Web ingress (ALB only) ---

resource "aws_vpc_security_group_ingress_rule" "web_http_from_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "HTTP from ALB only"
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

# --- App egress (least privilege: updates/git + DB) ---

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS for SSM, dnf, Docker Hub, git (via NAT from private subnet)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

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

# --- Web egress (updates/git only — deliberately NO database rule) ---

resource "aws_vpc_security_group_egress_rule" "web_https_out" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS for SSM, dnf, Docker Hub, git (via NAT from private subnet)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "web_dns_out" {
  security_group_id = aws_security_group.web.id
  description       = "DNS to VPC resolver only (blocks DNS exfiltration)"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

# --- DB ingress (no egress rules: stateful responses still flow) ---

resource "aws_vpc_security_group_ingress_rule" "db_postgres_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from application SG only"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app.id
}
