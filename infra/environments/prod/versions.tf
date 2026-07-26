terraform {
  required_version = ">= 1.10.0" # use_lockfile (S3 native state locking)

  # Remote state (README gap #4). Apply infra/global first, replace ACCOUNT_ID
  # (see the global stack's `tfstate_bucket` output), uncomment, then run:
  #   terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket       = "popo-tfstate-ACCOUNT_ID"
  #   key          = "prod/terraform.tfstate"
  #   region       = "eu-west-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }

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
