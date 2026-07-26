terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # This stack intentionally keeps LOCAL state: it creates the S3 bucket that
  # the dev/prod stacks use as their remote backend (chicken-and-egg).
  # It contains no secret material — only account-level bucket/trail config.
}
