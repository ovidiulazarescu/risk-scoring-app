terraform {
  required_version = ">= 1.12.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

# Used to build a globally unique bucket name
data "aws_caller_identity" "current" {}

# Bucket that will store the Terraform state file.
# NOTE: if this AWS account already has a tf-state-<account-id> bucket from another
# project (e.g. risk-api), skip this stack entirely and reuse that bucket — the two
# projects use different state keys (see the `key` in ../aws/main.tf) so they won't collide.
resource "aws_s3_bucket" "state" {
  bucket = "tf-state-${data.aws_caller_identity.current.account_id}"

  # Allows terraform destroy to remove the bucket even when it
  # still contains state files and old object versions
  force_destroy = true

  tags = {
    Name    = "tf-state"
    Purpose = "terraform-remote-state"
  }
}

# Keep old versions of the state file so it can be recovered
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

output "state_bucket_name" {
  description = "Name of the S3 bucket that stores Terraform state"
  value       = aws_s3_bucket.state.bucket
}
