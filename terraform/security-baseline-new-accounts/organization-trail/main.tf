# Deploy this module ONCE, from the Organizations management account (or
# a registered delegated administrator account for CloudTrail). It
# creates a single organization trail that automatically covers every
# account in the Organization - do not apply it more than once, and do
# not also create per-account trails in member accounts.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_kms_key" "trail" {
  description         = "Encrypts the Organization CloudTrail trail's log files."
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "EnableIAMUserPermissions"
          Effect    = "Allow"
          Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
          Action    = "kms:*"
          Resource  = "*"
        },
        {
          Sid       = "AllowCloudTrailToEncryptLogs"
          Effect    = "Allow"
          Principal = { Service = "cloudtrail.amazonaws.com" }
          Action    = "kms:GenerateDataKey*"
          Resource  = "*"
          Condition = {
            StringLike = {
              "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:${data.aws_partition.current.partition}:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"
            }
          }
        },
        {
          Sid       = "AllowCloudTrailToDescribeKey"
          Effect    = "Allow"
          Principal = { Service = "cloudtrail.amazonaws.com" }
          Action    = "kms:DescribeKey"
          Resource  = "*"
        },
      ],
      var.organization_id != "" ? [
        {
          Sid       = "AllowOrgAccountsToDecrypt"
          Effect    = "Allow"
          Principal = { AWS = "*" }
          Action    = ["kms:Decrypt", "kms:ReEncryptFrom"]
          Resource  = "*"
          Condition = {
            StringEquals = { "aws:PrincipalOrgID" = var.organization_id }
          }
        }
      ] : []
    )
  })
}

resource "aws_s3_bucket" "trail" {
  bucket = "${var.trail_name}-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.trail.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "TransitionAndExpire"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    expiration {
      days = var.log_retention_days # ~7 years by default - adjust to your requirement
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail.arn
      },
      {
        Sid       = "AWSCloudTrailWriteOrgTrail"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid       = "AWSCloudTrailWriteMemberAccountLogs"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
    ]
  })
}

resource "aws_cloudtrail" "organization" {
  depends_on = [aws_s3_bucket_policy.trail]

  name                          = var.trail_name
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.trail.arn
  enable_logging                = true
}
