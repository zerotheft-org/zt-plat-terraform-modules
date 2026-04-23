terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Separate state for secret manager — same bucket, different key, no DynamoDB (avoids cycle/lock issues)
  backend "s3" {
    bucket  = "zero-app-staging"
    key     = "terraform/state/staging-secret-manager.tfstate"
    region  = "us-east-1"
    encrypt = true
    # dynamodb_table intentionally omitted
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "stage"
      ManagedBy   = "Terraform"
      Project     = "SecretManager"
    }
  }
}
