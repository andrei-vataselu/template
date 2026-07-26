provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Application = var.application_name
      Project     = var.project_name
      Environment = var.environment
      EnvTier     = "nonprod"
      ManagedBy   = "terraform"
      Stack       = "${var.project_name}-${var.environment}"
      CostCenter  = var.cost_center
    }
  }
}

# CloudFront / WAF / ACM for CF must use us-east-1 (guide)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Application = var.application_name
      Project     = var.project_name
      Environment = var.environment
      EnvTier     = "nonprod"
      ManagedBy   = "terraform"
      Stack       = "${var.project_name}-${var.environment}"
      CostCenter  = var.cost_center
    }
  }
}
