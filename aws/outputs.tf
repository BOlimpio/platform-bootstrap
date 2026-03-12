# =============================================================================
# Bootstrap - Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# State Storage Outputs
# -----------------------------------------------------------------------------

output "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.state.arn
}

output "state_bucket_region" {
  description = "Region of the S3 bucket"
  value       = var.aws_region
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC Outputs
# -----------------------------------------------------------------------------

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_actions_role_arn" {
  description = "ARN of the IAM role for GitHub Actions"
  value       = aws_iam_role.github_actions.arn
}

output "github_actions_role_name" {
  description = "Name of the IAM role for GitHub Actions"
  value       = aws_iam_role.github_actions.name
}

# -----------------------------------------------------------------------------
# Backend Configuration Block
# -----------------------------------------------------------------------------

output "backend_config" {
  description = "Terraform backend configuration block to use in your projects"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.id}"
        key            = "terraform.tfstate"  # Customize per environment
        region         = "${var.aws_region}"
        use_lockfile   = true
        encrypt        = true
      }
    }
  EOT
}

# -----------------------------------------------------------------------------
# GitHub Actions Configuration
# -----------------------------------------------------------------------------

output "github_actions_env_vars" {
  description = "Environment variables to set in GitHub Actions"
  value = {
    AWS_ROLE_ARN = aws_iam_role.github_actions.arn
    AWS_REGION   = var.aws_region
  }
}

output "github_actions_permissions_snippet" {
  description = "Permissions block to add to GitHub Actions workflow"
  value       = <<-EOT
    permissions:
      id-token: write   # Required for OIDC
      contents: read    # Required for checkout
  EOT
}

output "github_actions_aws_auth_step" {
  description = "AWS authentication step for GitHub Actions"
  value       = <<-EOT
    - name: Configure AWS credentials
      uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: ${aws_iam_role.github_actions.arn}
        aws-region: ${var.aws_region}
  EOT
}
