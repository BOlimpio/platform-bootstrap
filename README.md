# platform-bootstrap

> **Role:** AWS Foundation — executed **once per AWS account** by the Platform Team.

This repository provisions the foundational AWS infrastructure required by all other Terraform repositories in the ecosystem. It solves the classic "chicken-and-egg" problem: you need an S3 bucket to store remote Terraform state, but you can't use S3 as a backend until the bucket exists.

---

## Table of Contents

- [Architecture](#architecture)
- [Resources Created](#resources-created)
- [How It Fits in the Ecosystem](#how-it-fits-in-the-ecosystem)
- [Prerequisites](#prerequisites)
- [Step-by-Step Setup](#step-by-step-setup)
- [Configuration Reference](#configuration-reference)
- [Outputs Reference](#outputs-reference)
- [State Management](#state-management)
- [IAM Permissions Reference](#iam-permissions-reference)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      platform-bootstrap                          │
│                                                                  │
│  ┌───────────────────┐    ┌──────────────────────────────────┐  │
│  │   S3 State Bucket │    │      IAM Role + Policies          │  │
│  │                   │    │                                   │  │
│  │  • AES-256 encrypt│    │  ┌─────────────────────────────┐ │  │
│  │  • versioning     │    │  │  terraform-state-access      │ │  │
│  │  • native locking │    │  │  S3: get/put/list/lock        │ │  │
│  │  • TLS enforced   │    │  └─────────────────────────────┘ │  │
│  │  • public blocked │    │  ┌─────────────────────────────┐ │  │
│  └───────────────────┘    │  │  terraform-resources-access  │ │  │
│                            │  │  EC2, IAM, VPC, S3, SQS,    │ │  │
│  ┌───────────────────┐    │  │  Lambda, CloudWatch Logs     │ │  │
│  │   OIDC Provider   │    │  └─────────────────────────────┘ │  │
│  │                   │    └──────────────────────────────────┘  │
│  │  GitHub ──► AWS   │                                          │
│  │  (no static creds)│                                          │
│  └───────────────────┘                                          │
└─────────────────────────────────────────────────────────────────┘
          │                               │
          ▼                               ▼
   Used by all                    Assumed by all
   environments                   GitHub Actions jobs
   as S3 backend                   via OIDC (no secrets)
```

---

## Resources Created

| Resource | Description |
|---|---|
| `aws_s3_bucket` (state) | Remote state bucket — versioned, AES-256 encrypted, public access blocked |
| `aws_s3_bucket_policy` | Bucket policy enforcing TLS-only access (`aws:SecureTransport`) |
| `aws_s3_bucket_versioning` | State file versioning for history and rollback |
| `aws_s3_bucket_server_side_encryption_configuration` | AES-256 server-side encryption |
| `aws_s3_bucket_public_access_block` | All four public-access block settings enabled |
| `aws_s3_bucket` (logs, optional) | Separate access log bucket with 30-day IA transition, 90-day expiry lifecycle |
| `aws_iam_openid_connect_provider` | GitHub OIDC provider (`token.actions.githubusercontent.com`) |
| `aws_iam_role` | Role assumed by GitHub Actions via OIDC — **zero long-lived credentials** |
| `aws_iam_policy` (state) | `terraform-state-access` — S3 permissions for remote state operations |
| `aws_iam_policy` (resources) | `terraform-resources-access` — all permissions for playground infrastructure |

---

## How It Fits in the Ecosystem

```
platform-bootstrap
    │
    ├── creates ──► S3 state bucket  ◄── used as backend by platform-playground
    ├── creates ──► GitHub OIDC provider
    └── creates ──► IAM role ◄── assumed by all platform-workflows CI/CD jobs via OIDC
```

**Why a dedicated bootstrap repo?**

- The S3 state bucket **must exist before** any other repo can use it as a Terraform backend
- OIDC provider and IAM role are **account-level** resources — created once, shared across all repos and environments
- Separating bootstrap enforces the principle that foundational resources are managed independently from application infrastructure
- When IAM permissions need expanding (e.g., a new AWS service is added), only this repo changes

---

## Prerequisites

Before running bootstrap, ensure you have:

1. **AWS CLI configured** with credentials that have `AdministratorAccess` (or sufficient permissions to create S3, IAM, and OIDC resources):
   ```bash
   aws configure
   aws sts get-caller-identity   # confirm identity and account
   ```

2. **Terraform >= 1.6.0** installed:
   ```bash
   terraform version
   ```

3. **GitHub repository already created** — you need the exact org name and repo name for the OIDC trust conditions

---

## Step-by-Step Setup

### 1. Clone and navigate to the module

```bash
git clone <your-platform-bootstrap-repo-url>
cd platform-bootstrap/aws
```

### 2. Configure `terraform.tfvars`

```hcl
# platform-bootstrap/aws/terraform.tfvars

project_name        = "platform-playground"   # used in bucket name and resource tags
environment         = "shared"
aws_region          = "us-east-1"
github_org          = "YourGitHubOrg"         # exact GitHub org name (case-sensitive)
github_repository   = "platform-playground"   # repo name only — no org prefix
allowed_branches    = ["*"]                   # or restrict: ["main", "refs/tags/*"]
allow_pull_requests = true                    # allow OIDC from PR workflow runs
```

> **Security note:** `terraform.tfvars` is tracked in git as a configuration example. It contains no secrets — all values are non-sensitive infrastructure configuration.

### 3. Initialize, plan, and apply

```bash
terraform init
terraform plan    # review all resources before creating
terraform apply   # type "yes" to confirm
```

Expected output after apply:
```
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.

Outputs:

state_bucket_name       = "platform-playground-shared-state"
github_actions_role_arn = "arn:aws:iam::123456789012:role/github-actions-platform-playground"

backend_config = <<-EOT
  backend "s3" {
    bucket       = "platform-playground-shared-state"
    key          = "environments/ENVIRONMENT_NAME/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
EOT
```

### 4. Configure GitHub repository secrets

In your **consumer repository** (e.g., `platform-playground`):

```
GitHub → Settings → Secrets and variables → Actions → New repository secret

Name:  AWS_ROLE_ARN
Value: <copy from terraform output github_actions_role_arn>
```

```
Name:  INFRACOST_API_KEY      (optional — enables cost estimation comments on PRs)
Value: <from infracost.io>
```

### 5. Configure GitHub Environments

Create three environments in your consumer repository:

```
GitHub → Settings → Environments → New environment

1. Name: "dev"
   Protection rules: none
   (CI/CD deploys automatically — no manual approval needed)

2. Name: "staging"
   Required reviewers: add your team or user
   (One approval required before apply runs)

3. Name: "production"
   Required reviewers: add your team or user
   Wait timer: 1 minute (set via GitHub API — see below)
   Deployment branches: Protected branches only
```

**Setting the production wait timer via GitHub CLI:**
```bash
# Find your user ID first
gh api /user --jq .id

# Set wait timer and reviewers
gh api --method PUT "repos/ORG/REPO/environments/production" \
  --field wait_timer=1 \
  --field prevent_self_review=false \
  --field "reviewers[][type]=User" \
  --field "reviewers[][id]=YOUR_USER_ID" \
  --field "deployment_branch_policy[protected_branches]=true" \
  --field "deployment_branch_policy[custom_branch_policies]=false"
```

> GitHub API accepts wait timers in **minutes only** (minimum = 1). There is no sub-minute granularity.

### 6. Verify OIDC authentication

Trigger any workflow in the consumer repository and check the `Configure AWS Credentials` step log. You should see:
```
Assuming role via OIDC
Successfully assumed role: arn:aws:iam::...
```

No static `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` should appear anywhere in the logs.

---

## Configuration Reference

| Variable | Type | Default | Description |
|---|---|---|---|
| `project_name` | `string` | required | Project identifier for resource names and tags. 3–63 chars, lowercase alphanumeric + hyphens. |
| `environment` | `string` | required | Environment tag value. Valid: `shared`, `dev`, `staging`, `prod`. |
| `aws_region` | `string` | `"us-east-1"` | AWS region for all bootstrap resources. |
| `github_org` | `string` | required | GitHub organization or personal account name. Case-sensitive. |
| `github_repository` | `string` | required | Repository name without the org prefix. |
| `allowed_branches` | `list(string)` | `["*"]` | Branches/refs allowed to assume the IAM role. Use `["main"]` to restrict to main branch. |
| `allow_pull_requests` | `bool` | `true` | Allow OIDC from pull request runs. Disable for tighter security if PRs should not deploy. |
| `state_bucket_force_destroy` | `bool` | `false` | Allow non-empty bucket deletion on `terraform destroy`. **Never enable in production.** |
| `enable_state_bucket_logging` | `bool` | `true` | Create a separate access logging bucket. |
| `additional_tags` | `map(string)` | `{}` | Extra tags applied to all resources. |

---

## Outputs Reference

| Output | Description | How to Use |
|---|---|---|
| `state_bucket_name` | S3 bucket name for remote state | Set in `backend "s3" { bucket = ... }` in consumer `versions.tf` |
| `state_bucket_arn` | Full ARN of the state bucket | Cross-account access or additional policy attachments |
| `state_bucket_region` | Bucket AWS region | Must match `region = ...` in `backend "s3"` block |
| `github_oidc_provider_arn` | ARN of the GitHub OIDC provider | Reference when creating additional IAM roles |
| `github_actions_role_arn` | ARN of the GitHub Actions role | Set as `AWS_ROLE_ARN` secret in consumer repos |
| `github_actions_role_name` | Name of the IAM role | Reference for additional policy attachments |
| `backend_config` | Ready-to-paste `backend "s3" {}` block | Copy to each environment's `versions.tf` |
| `github_actions_permissions_snippet` | YAML `permissions:` block | Paste into GitHub Actions workflow files |
| `github_actions_aws_auth_step` | Complete OIDC auth step YAML | Paste into workflow files requiring AWS access |

---

## State Management

### Why does bootstrap use local state?

```
bootstrap creates ──► S3 bucket
                           │
                           └── used as backend by platform-playground
                                       │
                           bootstrap CANNOT use its own output as backend
                           (bucket doesn't exist at init time)
                                       │
                           Solution: bootstrap keeps LOCAL state
```

The `terraform.tfstate` file lives on the machine where bootstrap is applied. This is explicitly documented in `versions.tf`.

### Protecting the local state file

```bash
# Option 1: Back up after first apply
cp aws/terraform.tfstate ~/secure-backups/bootstrap-$(date +%Y%m%d).tfstate

# Option 2: Migrate to S3 after the bucket exists (recommended)
cd aws
terraform init -migrate-state \
  -backend-config="bucket=platform-playground-shared-state" \
  -backend-config="key=bootstrap/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="use_lockfile=true"
```

If the state file is lost, you can recover by importing each resource:
```bash
terraform import aws_s3_bucket.state platform-playground-shared-state
terraform import aws_iam_openid_connect_provider.github \
  arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
# ... etc for each resource
```

### S3 Native Locking (Terraform >= 1.10)

Consumer repos use `use_lockfile = true` — creates a `.terraform.tfstate.lock.info` object in S3 during operations instead of requiring a DynamoDB table for locking. Benefits: simpler setup, one fewer resource, no additional cost.

---

## IAM Permissions Reference

### `terraform-state-access`

Scoped to the state bucket only:

| Action | Scope | Purpose |
|---|---|---|
| `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` | `bucket/*` | Read/write/delete state files |
| `s3:ListBucket` | `bucket` | List and discover state file keys |
| `s3:GetBucketVersioning`, `s3:GetBucketLocation` | `bucket` | State metadata validation |
| `s3:GetEncryptionConfiguration` | `bucket` | Verify encryption is configured |

### `terraform-resources-access`

Covers all services used in platform-playground:

| Service | Key Actions |
|---|---|
| **VPC / EC2** | Create/manage VPCs, subnets, route tables, IGWs, NAT gateways, Elastic IPs |
| **S3** | Bucket CRUD, policies, versioning, encryption, public access blocks, tagging |
| **SQS** | Queue CRUD, attributes, policies, tags |
| **Lambda** | Function CRUD, configuration, event source mappings, versions, aliases, concurrency |
| **CloudWatch Logs** | Log group CRUD, retention, tags (`logs:ListTagsForResource` required for AWS provider v6) |
| **IAM** | Role/policy CRUD, attachments, inline policies (`iam:PassRole` scoped to Lambda service principal) |
| **STS** | `GetCallerIdentity` for identity validation |

---

## Troubleshooting

**`Error: NoCredentialProviders`**
AWS CLI is not configured. Run `aws configure` or export `AWS_PROFILE`.

**`BucketAlreadyExists` or `BucketAlreadyOwnedByYou`**
S3 bucket names are globally unique. Add a unique suffix to `project_name` (e.g., include your AWS account ID).

**GitHub Actions: `Not authorized to perform sts:AssumeRoleWithWebIdentity`**
OIDC conditions don't match. Verify:
- `github_org` matches your GitHub org name exactly (case-sensitive)
- `github_repository` matches the repo name exactly
- The workflow branch matches `allowed_branches`
- `allow_pull_requests = true` if failing on a PR run

**`terraform plan` shows unexpected destroy of OIDC provider**
The OIDC provider already exists (created by another project). Import it instead of recreating:
```bash
terraform import aws_iam_openid_connect_provider.github \
  arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
```

**GitHub Actions: clock skew / token expired errors**
OIDC tokens have a short TTL. This is typically transient. If persistent, check runner system clock accuracy.
