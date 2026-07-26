# Guide §8: private DB subnets, public app subnet for lower-cost CloudFront origin.
# No NAT Gateway. Private route tables have no IGW route.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-igw"
  })
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 0)
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-public-a"
    Tier = "public"
  })
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 1)
  availability_zone       = var.azs[1]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-public-b"
    Tier = "public"
  })
}

resource "aws_subnet" "private_db_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 8)
  availability_zone = var.azs[0]

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-db-a"
    Tier = "database"
  })
}

resource "aws_subnet" "private_db_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 9)
  availability_zone = var.azs[1]

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-db-b"
    Tier = "database"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-public-rt"
  })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-private-rt"
  })
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_db_a" {
  subnet_id      = aws_subnet.private_db_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db_b" {
  subnet_id      = aws_subnet.private_db_b.id
  route_table_id = aws_route_table.private.id
}

# Flow logs on REJECTed traffic only — records port scans / SG blocks without
# paying to log the (much larger) accepted traffic. ~$0.05-0.50/mo at this scale.
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${var.project_name}-${var.environment}/flow-logs"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.project_name}-${var.environment}-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.project_name}-${var.environment}-flow-logs"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "rejected" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "REJECT"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-reject-flow-logs"
  })
}

# Free gateway endpoint — no hourly charge (guide §8)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-s3-gw"
  })
}

data "aws_region" "current" {}
