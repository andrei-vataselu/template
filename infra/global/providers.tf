provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Application = var.application_name
      Project     = var.project_name
      Environment = "global"
      ManagedBy   = "terraform"
      Stack       = "${var.project_name}-global"
    }
  }
}

# Root console sign-in events are global-service events delivered ONLY to us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Application = var.application_name
      Project     = var.project_name
      Environment = "global"
      ManagedBy   = "terraform"
      Stack       = "${var.project_name}-global"
    }
  }
}
