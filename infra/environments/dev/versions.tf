terraform {
  required_version = ">= 1.10.0" # use_lockfile (S3 native state locking)

  # Remote state (README gap #4). Steps:
  #   1. cd ../../global && terraform init && terraform apply   (creates the bucket)
  #   2. Replace ACCOUNT_ID below with your 12-digit account id
  #      (shown in the global stack's `tfstate_bucket` output)
  #   3. Uncomment, then run: terraform init -migrate-state
  #   4. Delete the now-migrated local terraform.tfstate* files
  #
  # backend "s3" {
  #   bucket       = "popo-tfstate-ACCOUNT_ID"
  #   key          = "dev/terraform.tfstate"
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
