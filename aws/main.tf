# =============================================================================
# Bootstrap - Main Configuration
# =============================================================================
# This configuration creates:
# 1. S3 bucket for Terraform state storage
# 2. GitHub OIDC provider and IAM role for CI/CD
# =============================================================================

locals {
  resource_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.additional_tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# Data sources for IAM policy
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# S3 Bucket for Terraform State
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket        = "${local.resource_prefix}-state"
  force_destroy = var.state_bucket_force_destroy

  tags = merge(local.common_tags, {
    Name    = "${local.resource_prefix}-state"
    Purpose = "terraform-state"
  })
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Optional: Access logging bucket
resource "aws_s3_bucket" "state_logs" {
  bucket        = "${local.resource_prefix}-state-logs"
  force_destroy = var.state_bucket_force_destroy

  tags = merge(local.common_tags, {
    Name    = "${local.resource_prefix}-state-logs"
    Purpose = "terraform-state-access-logs"
  })

  # checkov:skip=CKV_AWS_18: This bucket is a logging sink for the Terraform state bucket. Logging-to-self is not required.

}

resource "aws_s3_bucket_versioning" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "state" {
  bucket = aws_s3_bucket.state.id

  target_bucket = aws_s3_bucket.state_logs.id
  target_prefix = "access-logs/"
}

resource "aws_s3_bucket_lifecycle_configuration" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Bucket policy to enforce TLS
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# GitHub OIDC Provider
# -----------------------------------------------------------------------------

# Check if OIDC provider already exists
data "aws_iam_openid_connect_provider" "github" {
  count = 0 # Set to 1 if you want to use an existing provider
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = merge(local.common_tags, {
    Name    = "github-actions-oidc"
    Purpose = "github-actions-authentication"
  })
}

# -----------------------------------------------------------------------------
# IAM Role for GitHub Actions
# -----------------------------------------------------------------------------

locals {
  # Build list of allowed subjects
  branch_subjects = [for branch in var.allowed_branches :
    "repo:${var.github_org}/${var.github_repository}:${branch}"
  ]

  pr_subjects = var.allow_pull_requests ? [
    "repo:${var.github_org}/${var.github_repository}:pull_request"
  ] : []

  all_subjects = concat(local.branch_subjects, local.pr_subjects)
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.all_subjects
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-${var.github_org}-${var.github_repository}"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
  description        = "IAM role for GitHub Actions OIDC authentication"

  tags = merge(local.common_tags, {
    Name       = "github-actions-${var.github_org}-${var.github_repository}"
    Purpose    = "github-actions-ci-cd"
    Repository = "${var.github_org}/${var.github_repository}"
  })
}

# IAM Policy for Terraform State Access
data "aws_iam_policy_document" "terraform_state" {
  # S3 state bucket permissions
  statement {
    sid    = "S3StateAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning"
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*"
    ]
  }

  # KMS permissions for encrypted state
  statement {
    sid    = "KMSAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "terraform_state" {
  name        = "terraform-state-access-${local.resource_prefix}"
  description = "Permissions for Terraform state access"
  policy      = data.aws_iam_policy_document.terraform_state.json

  tags = merge(local.common_tags, {
    Name    = "terraform-state-access-${local.resource_prefix}"
    Purpose = "terraform-state-access"
  })
}

resource "aws_iam_role_policy_attachment" "terraform_state" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.terraform_state.arn
}

# Resource management permissions for Terraform deployments
data "aws_iam_policy_document" "terraform_resources" {
  # EC2 read operations (for VPC planning/refresh)
  # ec2:Describe*/Get* do NOT support resource-level permissions — resources = ["*"] required by AWS.
  # See .checkov.yaml skip CKV_AWS_356 for justification.
  statement {
    sid    = "EC2ReadAccess"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:Get*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # IAM read permissions
  statement {
    sid    = "IAMReadAccess"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListRoles",
      "iam:ListPolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/*"
    ]
  }

  # S3 permissions (for S3 module)
  # s3:* is scoped to specific bucket name prefixes (not resources = ["*"]).
  # checkov:skip=CKV_AWS_355: s3:* is scoped to specific bucket ARN prefixes, not wildcard resources.
  statement {
    sid     = "S3BucketAccess"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${local.resource_prefix}*",
      "arn:aws:s3:::${local.resource_prefix}*/*",
      "arn:aws:s3:::tcip-*",
      "arn:aws:s3:::tcip-*/*",
    ]
  }

  # s3:ListAllMyBuckets is account-level and cannot be scoped to a specific ARN.
  # See .checkov.yaml skip CKV_AWS_356 for justification.
  statement {
    sid       = "S3ListAllBuckets"
    effect    = "Allow"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  # SQS management (for SQS module)
  statement {
    sid    = "SQSManagement"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:SetQueueAttributes",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ListQueues",
      "sqs:TagQueue",
      "sqs:UntagQueue",
      "sqs:ListQueueTags",
    ]
    resources = [
      "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:tcip-*",
    ]
  }

  # Lambda management (for Lambda module)
  statement {
    sid    = "LambdaManagement"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:GetFunctionConcurrency",
      "lambda:ListFunctions",
      "lambda:ListVersionsByFunction",
      "lambda:ListAliases",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:GetPolicy",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:ListTags",
      "lambda:PutFunctionConcurrency",
      "lambda:DeleteFunctionConcurrency",
    ]
    resources = [
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:tcip-*",
    ]
  }

  # IAM Role management for Lambda execution roles
  # Resources scoped to tcip-* naming convention used by test modules.
  statement {
    sid    = "IAMRoleManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      # Inline role policies (used by Lambda DLQ policy)
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      # Required by Terraform when deleting IAM roles
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/tcip-*"]
  }

  # PassRole allows the github-actions role to pass IAM roles to Lambda.
  statement {
    sid    = "IAMPassRole"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/tcip-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid    = "STSValidation"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity"
    ]
    resources = ["*"]
  }

  # VPC core resources (required by all environments)
  statement {
    sid    = "VPCCoreManagement"
    effect = "Allow"
    actions = [
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
    ]
    resources = [
      "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:vpc/*",
      "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:subnet/*",
      "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:internet-gateway/*",
      "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:route-table/*",
    ]
  }

  # Security groups (kept for completeness; may be needed by VPC-attached services)
  statement {
    sid    = "VPCSecurityGroupManagement"
    effect = "Allow"
    actions = [
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:ModifySecurityGroupRules",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
    ]
    resources = [
      "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:security-group/*",
      "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:vpc/*",
    ]
  }

  # Allow tagging EC2 resources at creation time
  # ec2:CreateAction restricts tagging to specific create operations only.
  statement {
    sid    = "EC2CreateTags"
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values = [
        "CreateVpc",
        "CreateSubnet",
        "CreateInternetGateway",
        "CreateRouteTable",
        "CreateSecurityGroup",
        "CreateNatGateway",
        "AllocateAddress",
      ]
    }
  }

  # CloudWatch Logs (for Lambda log groups)
  statement {
    sid    = "CloudWatchLogsManagement"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:ListTagsLogGroup",
      "logs:ListTagsForResource",
      "logs:TagLogGroup",
      "logs:TagResource",
      "logs:UntagLogGroup",
      "logs:UntagResource",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
  }

  # NAT Gateway and Elastic IP (required when enable_nat_gateway=true)
  statement {
    sid    = "NATGatewayManagement"
    effect = "Allow"
    actions = [
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:CreateNatGateway",
      "ec2:DeleteNatGateway",
      "ec2:DescribeNatGateways",
      "ec2:DescribeAddresses",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

}

resource "aws_iam_policy" "terraform_resources" {
  name        = "terraform-resources-access-${local.resource_prefix}"
  description = "Permissions for Terraform resource management (Lambda, SQS, VPC, S3, CloudWatch Logs, NAT Gateway)"
  policy      = data.aws_iam_policy_document.terraform_resources.json

  tags = merge(local.common_tags, {
    Name    = "terraform-resources-access-${local.resource_prefix}"
    Purpose = "terraform-resources-access"
  })
}

resource "aws_iam_role_policy_attachment" "terraform_resources" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.terraform_resources.arn
}
