/*
  Account-level stack — apply ONCE, before the env stacks (README §3 items 2/3/7):
  - S3 bucket for remote Terraform state (versioned, encrypted, TLS-only)
  - CloudTrail: management events (first copy free) to a 90-day S3 bucket
  - Root account usage alerts (console sign-in + API calls) via SNS email
  - GuardDuty (~$1-4/mo, toggleable) + IAM Access Analyzer (free tier)

  Expected cost: ~$0-1/mo without GuardDuty, ~$1-5/mo with it.
*/

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Remote Terraform state bucket (envs migrate to it via versions.tf backend)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    # SSE-KMS with the AWS-managed aws/s3 key (no KMS key cost)
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Principal lock: only account root + GitHub Terraform CI role may use the
# state bucket. Local applies must use root (or assume that role). AWS service
# principals (e.g. future inventory/replication) are exempt from the Deny.
locals {
  tfstate_allowed_principal_arns = compact(concat(
    [
      "arn:aws:iam::${local.account_id}:root",
    ],
    var.enable_github_oidc ? [
      aws_iam_role.github_terraform[0].arn,
      "arn:aws:sts::${local.account_id}:assumed-role/${aws_iam_role.github_terraform[0].name}/*",
    ] : [],
  ))
}

resource "aws_s3_bucket_policy" "tfstate_tls_only" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAndGithubTerraform"
        Effect = "Allow"
        Principal = {
          AWS = concat(
            ["arn:aws:iam::${local.account_id}:root"],
            var.enable_github_oidc ? [aws_iam_role.github_terraform[0].arn] : []
          )
        }
        Action = "s3:*"
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
      },
      {
        Sid       = "DenyOtherPrincipals"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
        Condition = {
          ArnNotLike = {
            "aws:PrincipalArn" = local.tfstate_allowed_principal_arns
          }
          Bool = {
            "aws:PrincipalIsAWSService" = "false"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# ---------------------------------------------------------------------------
# DNS — hosted zone for the registered domain ($0.50/mo)
# After apply: set the registrar's nameservers to the `name_servers` output
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "main" {
  count = var.domain_name != "" ? 1 : 0

  name    = var.domain_name
  comment = "Managed by Terraform (infra/global) — registrar NS must point here"
}

# ---------------------------------------------------------------------------
# CloudTrail — management events, all regions (first copy is free)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "cloudtrail" {
  bucket = "${var.project_name}-cloudtrail-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.cloudtrail_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${local.account_id}:trail/${var.project_name}-management"
          }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${local.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${local.account_id}:trail/${var.project_name}-management"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.cloudtrail.arn,
          "${aws_s3_bucket.cloudtrail.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

resource "aws_cloudtrail" "management" {
  name                          = "${var.project_name}-management"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  # Management events only — the free tier. No data events (those cost money).

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ---------------------------------------------------------------------------
# Root account usage alerts (README gap #3 — detect until you retire root)
# ---------------------------------------------------------------------------

# Console sign-ins land in us-east-1 (global service events)
resource "aws_sns_topic" "root_alerts_use1" {
  provider = aws.us_east_1
  name     = "${var.project_name}-root-usage-alerts"
}

resource "aws_sns_topic_subscription" "root_alerts_use1" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.root_alerts_use1.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "root_alerts_use1" {
  provider = aws.us_east_1
  arn      = aws_sns_topic.root_alerts_use1.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.root_alerts_use1.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "root_signin" {
  provider    = aws.us_east_1
  name        = "${var.project_name}-root-console-signin"
  description = "Any root console sign-in"

  event_pattern = jsonencode({
    detail-type = ["AWS Console Sign In via CloudTrail"]
    detail = {
      userIdentity = { type = ["Root"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "root_signin" {
  provider = aws.us_east_1
  rule     = aws_cloudwatch_event_rule.root_signin.name
  arn      = aws_sns_topic.root_alerts_use1.arn
}

# Root API calls surface in the region where they happen (home region here)
resource "aws_sns_topic" "root_alerts_home" {
  name = "${var.project_name}-root-usage-alerts"
}

resource "aws_sns_topic_subscription" "root_alerts_home" {
  topic_arn = aws_sns_topic.root_alerts_home.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "root_alerts_home" {
  arn = aws_sns_topic.root_alerts_home.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.root_alerts_home.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "root_api" {
  name        = "${var.project_name}-root-api-usage"
  description = "Any root API call in the home region"

  event_pattern = jsonencode({
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      userIdentity = { type = ["Root"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "root_api" {
  rule = aws_cloudwatch_event_rule.root_api.name
  arn  = aws_sns_topic.root_alerts_home.arn
}

# ---------------------------------------------------------------------------
# GuardDuty + IAM Access Analyzer (README gap #7)
# ---------------------------------------------------------------------------

resource "aws_guardduty_detector" "this" {
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "SIX_HOURS"
}

# External-access analyzer is free; the paid tier is "unused access" (not used)
resource "aws_accessanalyzer_analyzer" "external" {
  analyzer_name = "${var.project_name}-external-access"
  type          = "ACCOUNT"
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC — pipeline can plan/apply without long-lived AWS keys
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # Pin known GitHub Actions CA thumbprints (dynamic TLS lookup can lag / drift).
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4c7df47eefc",
  ]
}

# Cap CI role privileges: no IAM users/keys; no PutRolePolicy on the CI roles
# themselves (defense in depth alongside DenySelfEscalation below).
resource "aws_iam_policy" "permissions_boundary" {
  count = var.enable_github_oidc ? 1 : 0

  name        = "${var.project_name}-ci-permissions-boundary"
  description = "Permissions boundary for GitHub OIDC CI roles"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAllExceptBoundaryDenies"
        Effect = "Allow"
        NotAction = [
          "iam:CreateUser",
          "iam:CreateAccessKey",
        ]
        Resource = "*"
      },
      {
        Sid      = "DenyCreateUserAndAccessKeys"
        Effect   = "Deny"
        Action   = ["iam:CreateUser", "iam:CreateAccessKey"]
        Resource = "*"
      },
      {
        Sid    = "DenyPutRolePolicyOnGithubRoles"
        Effect = "Deny"
        Action = "iam:PutRolePolicy"
        Resource = [
          "arn:aws:iam::${local.account_id}:role/${var.project_name}-github-terraform",
          "arn:aws:iam::${local.account_id}:role/${var.project_name}-github-deploy",
        ]
      }
    ]
  })
}

resource "aws_iam_role" "github_terraform" {
  count = var.enable_github_oidc ? 1 : 0

  name                 = "${var.project_name}-github-terraform"
  permissions_boundary = aws_iam_policy.permissions_boundary[0].arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # No repo:* — only main pushes and GitHub Environments (dev/prod).
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_repository}:ref:refs/heads/main",
            "repo:${var.github_repository}:environment:dev",
            "repo:${var.github_repository}:environment:prod",
            "repo:${split("/", var.github_repository)[0]}@*/${split("/", var.github_repository)[1]}@*:ref:refs/heads/main",
            "repo:${split("/", var.github_repository)[0]}@*/${split("/", var.github_repository)[1]}@*:environment:dev",
            "repo:${split("/", var.github_repository)[0]}@*/${split("/", var.github_repository)[1]}@*:environment:prod",
          ]
        }
      }
    }]
  })

  tags = {
    Application = var.application_name
    Environment = "global"
  }
}

# Scoped CI permissions (was AdministratorAccess): PowerUser covers every
# non-IAM service Terraform touches; the inline policy below adds only the
# IAM lifecycle for project-prefixed roles/policies/instance-profiles.
# A leaked Actions token can no longer administer IAM account-wide.
resource "aws_iam_role_policy_attachment" "github_terraform_poweruser" {
  count = var.enable_github_oidc ? 1 : 0

  role       = aws_iam_role.github_terraform[0].name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "github_terraform_iam_scoped" {
  count = var.enable_github_oidc ? 1 : 0

  name = "${var.project_name}-github-terraform-iam-scoped"
  role = aws_iam_role.github_terraform[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "IamRead"
        Effect   = "Allow"
        Action   = ["iam:Get*", "iam:List*"]
        Resource = "*"
      },
      {
        Sid    = "ProjectIamLifecycle"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:UpdateRole",
          "iam:UpdateRoleDescription",
          "iam:UpdateAssumeRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:UntagInstanceProfile"
        ]
        Resource = [
          "arn:aws:iam::*:role/${var.project_name}-*",
          "arn:aws:iam::*:policy/${var.project_name}-*",
          "arn:aws:iam::*:instance-profile/${var.project_name}-*"
        ]
      },
      {
        # Closes REPORT C2 — CI must never mutate its own trust/policies.
        Sid    = "DenySelfEscalation"
        Effect = "Deny"
        Action = [
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole",
          "iam:DeleteRole",
          "iam:CreatePolicyVersion",
          "iam:SetDefaultPolicyVersion"
        ]
        Resource = [
          "arn:aws:iam::*:role/${var.project_name}-github-terraform",
          "arn:aws:iam::*:role/${var.project_name}-github-deploy",
        ]
      },
      {
        Sid      = "PassProjectRolesToServices"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::*:role/${var.project_name}-*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "ec2.amazonaws.com",
              "vpc-flow-logs.amazonaws.com",
              "rds.amazonaws.com",
              "cognito-idp.amazonaws.com",
              "lambda.amazonaws.com"
            ]
          }
        }
      },
      {
        Sid      = "ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
      }
    ]
  })
}

# Minimal CD role — ASG refresh only (FE/BE deploy workflows).
resource "aws_iam_role" "github_deploy" {
  count = var.enable_github_oidc ? 1 : 0

  name                 = "${var.project_name}-github-deploy"
  permissions_boundary = aws_iam_policy.permissions_boundary[0].arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_repository}:ref:refs/heads/main",
            "repo:${var.github_repository}:environment:dev",
            "repo:${var.github_repository}:environment:prod",
            "repo:${split("/", var.github_repository)[0]}@*/${split("/", var.github_repository)[1]}@*:ref:refs/heads/main",
            "repo:${split("/", var.github_repository)[0]}@*/${split("/", var.github_repository)[1]}@*:environment:dev",
            "repo:${split("/", var.github_repository)[0]}@*/${split("/", var.github_repository)[1]}@*:environment:prod",
          ]
        }
      }
    }]
  })

  tags = {
    Application = var.application_name
    Environment = "global"
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  count = var.enable_github_oidc ? 1 : 0

  name = "${var.project_name}-github-deploy"
  role = aws_iam_role.github_deploy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AsgRefresh"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeInstanceRefreshes",
          "autoscaling:StartInstanceRefresh",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
        ]
        Resource = "*"
      },
      {
        Sid    = "PinAppGitSha"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:AddTagsToResource",
        ]
        Resource = "arn:aws:ssm:*:${local.account_id}:parameter/${var.project_name}/*/app-git-sha"
      }
    ]
  })
}
