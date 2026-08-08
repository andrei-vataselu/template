terraform {
  required_version = ">= 1.10.0"

  # Partial S3 backend — filled at init via -backend-config=../../backends/prod.hcl
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
