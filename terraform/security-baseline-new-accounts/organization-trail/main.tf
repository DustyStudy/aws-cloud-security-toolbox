# Deploy this module ONCE, from the Organizations management account (or
# a registered delegated administrator account for CloudTrail). It
# creates a single organization trail that automatically covers every
# account in the Organization - do not apply it more than once, and do
# not also create per-account trails in member accounts.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # A syntactically-valid but non-matching org ID, so the decrypt
  # statement below is always present (helps static analysis tools that
  # struggle with conditionally-omitted policy statements) while being
  # functionally inert when organization_id isn't set.
  effective_org_id = var.organization_id != "" ? var.organization_id : "o-00000000disabled"
}

resource "aws_kms_key" "trail" {
  description         = "Encrypts the Organization CloudTrail trail's log files and CloudWatch Logs group."
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
      {
        Sid       = "AllowCloudWatchLogsUseOfKey"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/cloudtrail/${var.trail_name}"
          }
        }
      },
      {
        # Inert unless organization_id is set - see local.effective_org_id.
        # A wildcard principal scoped by an aws:PrincipalOrgID condition is
        # the standard AWS pattern for "any account in this org" grants -
        # there's no way to name specific account ARNs for accounts that
        # may not exist yet.
        Sid       = "AllowOrgAccountsToDecrypt"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Decrypt", "kms:ReEncryptFrom"]
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:PrincipalOrgID" = local.effective_org_id }
        }
      },
    ]
  })
}

resource "aws_s3_bucket" "access_logs" {
  # checkov:skip=CKV_AWS_144: Access-log bucket for the trail bucket below;
  # cross-region replication of the access logs themselves is unnecessary
  # overhead for a starter template. Enable if your compliance regime
  # requires it.
  # checkov:skip=CKV2_AWS_62: Pure write-once access-log target - nothing
  # downstream consumes events from it, so notifications add no value here.
  # checkov:skip=CKV_AWS_18: This IS the access-log destination bucket -
  # giving it its own access logs would be recursive.
  # checkov:skip=CKV_AWS_145: S3 server access log delivery only supports
  # SSE-S3 for the destination bucket, not SSE-KMS - this is a documented
  # AWS limitation, not an oversight.
  bucket = "${var.trail_name}-access-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "ExpireAccessLogs"
    status = "Enabled"

    expiration {
      days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "S3ServerAccessLogsPolicy"
      Effect    = "Allow"
      Principal = { Service = "logging.s3.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.access_logs.arn}/*"
      Condition = {
        ArnLike      = { "aws:SourceArn" = aws_s3_bucket.trail.arn }
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_s3_bucket" "trail" {
  # checkov:skip=CKV_AWS_144: Cross-region replication is deliberately not
  # included - it doubles storage cost and adds a second region/IAM role
  # for a starter template. Add an aws_s3_bucket_replication_configuration
  # if your compliance regime requires geographic redundancy for trail logs.
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

resource "aws_s3_bucket_logging" "trail" {
  bucket        = aws_s3_bucket.trail.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "trail-bucket-access-logs/"
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

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
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

resource "aws_s3_bucket_notification" "trail" {
  bucket      = aws_s3_bucket.trail.id
  eventbridge = true
}

resource "aws_sns_topic" "trail" {
  name              = "${var.trail_name}-notifications"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_policy" "trail" {
  arn = aws_sns_topic.trail.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudTrailPublish"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.trail.arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/${var.trail_name}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.trail.arn
}

resource "aws_iam_role" "cloudtrail_to_cloudwatch" {
  name = "${var.trail_name}-cloudwatch-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_to_cloudwatch" {
  name = "${var.trail_name}-cloudwatch-logs-policy"
  role = aws_iam_role.cloudtrail_to_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.trail.arn}:*"
    }]
  })
}

resource "aws_cloudtrail" "organization" {
  depends_on = [aws_s3_bucket_policy.trail, aws_iam_role_policy.cloudtrail_to_cloudwatch]

  name                          = var.trail_name
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.trail.arn
  enable_logging                = true
  sns_topic_name                = aws_sns_topic.trail.name
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_to_cloudwatch.arn
}
