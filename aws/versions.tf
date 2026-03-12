# =============================================================================
# Bootstrap - Terraform Version Requirements
# =============================================================================
# IMPORTANT: The bootstrap intentionally uses LOCAL state (no backend block).
#
# Reason: The bootstrap itself creates the S3 bucket used as a Terraform
# backend by other projects. Configuring an S3 backend here would create a
# chicken-and-egg problem — the bucket doesn't exist before the first apply.
#
# After applying, you may optionally migrate the bootstrap state to S3:
#   terraform init -migrate-state \
#     -backend-config="bucket=<state_bucket_name>" \
#     -backend-config="key=bootstrap/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="use_lockfile=true"
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }

  # No backend block — bootstrap uses local state by design.
  # See note above for optional state migration after first apply.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Purpose     = "terraform-state-bootstrap"
    }
  }
}
