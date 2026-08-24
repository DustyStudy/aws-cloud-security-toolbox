locals {
  deny_root_user_content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyRootUser"
      Effect    = "Deny"
      Action    = "*"
      Resource  = "*"
      Condition = { StringLike = { "aws:PrincipalArn" = "arn:*:iam::*:root" } }
    }]
  })

  deny_disable_security_services_content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDisableCloudTrail"
        Effect = "Deny"
        Action = [
          "cloudtrail:StopLogging",
          "cloudtrail:DeleteTrail",
          "cloudtrail:UpdateTrail",
          "cloudtrail:PutEventSelectors",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDisableConfig"
        Effect = "Deny"
        Action = [
          "config:DeleteConfigurationRecorder",
          "config:DeleteDeliveryChannel",
          "config:StopConfigurationRecorder",
          "config:DeleteConfigRule",
          "config:DeleteRemediationConfiguration",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDisableGuardDuty"
        Effect = "Deny"
        Action = [
          "guardduty:DeleteDetector",
          "guardduty:DisassociateFromMasterAccount",
          "guardduty:DisassociateMembers",
          "guardduty:DisableOrganizationAdminAccount",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDisableSecurityHub"
        Effect = "Deny"
        Action = [
          "securityhub:DisableSecurityHub",
          "securityhub:DisableImportFindingsForProduct",
          "securityhub:DeleteInsight",
        ]
        Resource = "*"
      },
    ]
  })

  require_imdsv2_content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyLaunchInstanceWithoutIMDSv2"
        Effect    = "Deny"
        Action    = "ec2:RunInstances"
        Resource  = "arn:*:ec2:*:*:instance/*"
        Condition = { StringNotEquals = { "ec2:MetadataHttpTokens" = "required" } }
      },
      {
        Sid       = "DenyDowngradeToIMDSv1"
        Effect    = "Deny"
        Action    = "ec2:ModifyInstanceMetadataOptions"
        Resource  = "*"
        Condition = { StringNotEquals = { "ec2:MetadataHttpTokens" = "required" } }
      },
    ]
  })

  deny_leave_organization_content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyLeaveOrganization"
      Effect   = "Deny"
      Action   = "organizations:LeaveOrganization"
      Resource = "*"
    }]
  })

  deny_disable_s3_public_access_block_content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyDisableAccountBlockPublicAcls"
        Effect    = "Deny"
        Action    = "s3:PutAccountPublicAccessBlock"
        Resource  = "*"
        Condition = { Bool = { "s3:PutAccountPublicAccessBlock:BlockPublicAcls" = "false" } }
      },
      {
        Sid       = "DenyDisableAccountBlockPublicPolicy"
        Effect    = "Deny"
        Action    = "s3:PutAccountPublicAccessBlock"
        Resource  = "*"
        Condition = { Bool = { "s3:PutAccountPublicAccessBlock:BlockPublicPolicy" = "false" } }
      },
      {
        Sid       = "DenyDisableAccountIgnorePublicAcls"
        Effect    = "Deny"
        Action    = "s3:PutAccountPublicAccessBlock"
        Resource  = "*"
        Condition = { Bool = { "s3:PutAccountPublicAccessBlock:IgnorePublicAcls" = "false" } }
      },
      {
        Sid       = "DenyDisableAccountRestrictPublicBuckets"
        Effect    = "Deny"
        Action    = "s3:PutAccountPublicAccessBlock"
        Resource  = "*"
        Condition = { Bool = { "s3:PutAccountPublicAccessBlock:RestrictPublicBuckets" = "false" } }
      },
      {
        Sid       = "DenyDisableBucketBlockPublicAcls"
        Effect    = "Deny"
        Action    = "s3:PutBucketPublicAccessBlock"
        Resource  = "*"
        Condition = { Bool = { "s3:PutBucketPublicAccessBlock:BlockPublicAcls" = "false" } }
      },
      {
        Sid       = "DenyDisableBucketBlockPublicPolicy"
        Effect    = "Deny"
        Action    = "s3:PutBucketPublicAccessBlock"
        Resource  = "*"
        Condition = { Bool = { "s3:PutBucketPublicAccessBlock:BlockPublicPolicy" = "false" } }
      },
      {
        Sid       = "DenyDisableBucketIgnorePublicAcls"
        Effect    = "Deny"
        Action    = "s3:PutBucketPublicAccessBlock"
        Resource  = "*"
        Condition = { Bool = { "s3:PutBucketPublicAccessBlock:IgnorePublicAcls" = "false" } }
      },
      {
        Sid       = "DenyDisableBucketRestrictPublicBuckets"
        Effect    = "Deny"
        Action    = "s3:PutBucketPublicAccessBlock"
        Resource  = "*"
        Condition = { Bool = { "s3:PutBucketPublicAccessBlock:RestrictPublicBuckets" = "false" } }
      },
    ]
  })

  restrict_regions_content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyAllOutsideAllowedRegions"
      Effect = "Deny"
      NotAction = [
        "a4b:*", "acm:*", "aws-marketplace-management:*", "aws-marketplace:*",
        "aws-portal:*", "budgets:*", "ce:*", "chime:*", "cloudfront:*", "config:*",
        "cur:*", "directconnect:*", "ec2:DescribeRegions", "ec2:DescribeAvailabilityZones",
        "fms:*", "globalaccelerator:*", "health:*", "iam:*", "importexport:*", "kms:*",
        "mobileanalytics:*", "networkmanager:*", "organizations:*", "pricing:*",
        "route53:*", "route53domains:*", "route53-recovery-cluster:*",
        "s3:GetAccountPublicAccessBlock", "shield:*", "sts:*", "support:*",
        "trustedadvisor:*", "waf-regional:*", "waf:*", "wafv2:*", "wellarchitected:*",
      ]
      Resource  = "*"
      Condition = { StringNotEquals = { "aws:RequestedRegion" = var.allowed_regions } }
    }]
  })

  # Policy name => (enabled?, JSON content). Iterated below to create
  # policies + attachments without repeating the same two resources six times.
  policies = {
    deny-root-user = {
      enabled     = var.enable_deny_root_user
      description = "Denies all actions taken as the account root user."
      content     = local.deny_root_user_content
    }
    deny-disable-security-services = {
      enabled     = var.enable_deny_disable_security_services
      description = "Denies disabling CloudTrail, Config, GuardDuty, or Security Hub."
      content     = local.deny_disable_security_services_content
    }
    require-imdsv2 = {
      enabled     = var.enable_require_imdsv2
      description = "Denies launching or modifying EC2 instances without IMDSv2 required."
      content     = local.require_imdsv2_content
    }
    deny-leave-organization = {
      enabled     = var.enable_deny_leave_organization
      description = "Denies member accounts from leaving the Organization."
      content     = local.deny_leave_organization_content
    }
    deny-disable-s3-public-access-block = {
      enabled     = var.enable_deny_disable_s3_public_access_block
      description = "Denies disabling S3 Block Public Access at the account or bucket level."
      content     = local.deny_disable_s3_public_access_block_content
    }
    restrict-regions = {
      enabled     = var.enable_restrict_regions
      description = "Denies actions outside the allow-listed regions (global services exempted)."
      content     = local.restrict_regions_content
    }
  }

  enabled_policies = { for name, p in local.policies : name => p if p.enabled }

  # Cartesian product of enabled policy name x target ID, so each policy
  # gets attached to every target via its own attachment resource.
  attachments = {
    for pair in setproduct(keys(local.enabled_policies), var.target_ids) :
    "${pair[0]}|${pair[1]}" => { policy_name = pair[0], target_id = pair[1] }
  }
}

resource "aws_organizations_policy" "this" {
  for_each = local.enabled_policies

  name        = "${var.name_prefix}-${each.key}"
  description = each.value.description
  type        = "SERVICE_CONTROL_POLICY"
  content     = each.value.content
}

resource "aws_organizations_policy_attachment" "this" {
  for_each = local.attachments

  policy_id = aws_organizations_policy.this[each.value.policy_name].id
  target_id = each.value.target_id
}
