# =============================================================================
# Bootstrap - Input Variables
# =============================================================================

variable "project_name" {
  description = "Name of the project (used for resource naming)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.project_name))
    error_message = "Project name must be lowercase alphanumeric with hyphens, 3-63 characters."
  }
}

variable "environment" {
  description = "Environment name (e.g., shared, dev, prod)"
  type        = string
  default     = "shared"

  validation {
    condition     = contains(["shared", "dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: shared, dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

# -----------------------------------------------------------------------------
# GitHub OIDC Configuration
# -----------------------------------------------------------------------------

variable "github_org" {
  description = "GitHub organization name"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]*$", var.github_org))
    error_message = "GitHub organization name must be alphanumeric with hyphens."
  }
}

variable "github_repository" {
  description = "GitHub repository name (without org prefix)"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+$", var.github_repository))
    error_message = "GitHub repository name contains invalid characters."
  }
}

variable "allowed_branches" {
  description = "List of branches allowed to assume the IAM role"
  type        = list(string)
  default     = ["*"] # Allow all branches by default
}

variable "allow_pull_requests" {
  description = "Allow pull request workflows to assume the IAM role"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# State Bucket Configuration
# -----------------------------------------------------------------------------

variable "state_bucket_force_destroy" {
  description = "Allow destroying the state bucket even if it contains objects"
  type        = bool
  default     = false
}

variable "enable_state_bucket_logging" {
  description = "Enable access logging for the state bucket"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
