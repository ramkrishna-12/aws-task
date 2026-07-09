terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Recommended: store state remotely instead of locally once you've bootstrapped
  # the S3 bucket + DynamoDB lock table (see docs/SETUP.md).
  #
  # backend "s3" {
  #   bucket         = "taskmaster-tfstate-<account_id>"
  #   key            = "taskmaster/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "taskmaster-tf-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}
