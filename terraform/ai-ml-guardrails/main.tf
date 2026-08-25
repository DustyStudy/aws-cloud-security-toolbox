locals {
  deny_disable_bedrock_logging_and_guardrails_content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyDisableBedrockInvocationLogging"
        Effect   = "Deny"
        Action   = "bedrock:DeleteModelInvocationLoggingConfiguration"
        Resource = "*"
      },
      {
        Sid      = "DenyDeleteBedrockGuardrails"
        Effect   = "Deny"
        Action   = "bedrock:DeleteGuardrail"
        Resource = "*"
      },
    ]
  })

  restrict_bedrock_foundation_models_content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyDisallowedFoundationModels"
      Effect = "Deny"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      NotResource = [
        for pattern in var.allowed_bedrock_model_patterns :
        "arn:*:bedrock:*::foundation-model/${pattern}"
      ]
    }]
  })

  lockdown_sagemaker_notebooks_content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenySageMakerDirectInternetAccess"
        Effect    = "Deny"
        Action    = ["sagemaker:CreateNotebookInstance", "sagemaker:UpdateNotebookInstance"]
        Resource  = "*"
        Condition = { StringEquals = { "sagemaker:DirectInternetAccess" = "Enabled" } }
      },
      {
        Sid       = "DenySageMakerRootAccess"
        Effect    = "Deny"
        Action    = ["sagemaker:CreateNotebookInstance", "sagemaker:UpdateNotebookInstance"]
        Resource  = "*"
        Condition = { StringEquals = { "sagemaker:RootAccess" = "Enabled" } }
      },
      {
        Sid       = "DenySageMakerNotebookWithoutVPC"
        Effect    = "Deny"
        Action    = "sagemaker:CreateNotebookInstance"
        Resource  = "*"
        Condition = { Null = { "sagemaker:VpcSubnets" = "true" } }
      },
    ]
  })

  require_sagemaker_encryption_content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenySageMakerNotebookWithoutKMS"
        Effect    = "Deny"
        Action    = "sagemaker:CreateNotebookInstance"
        Resource  = "*"
        Condition = { Null = { "sagemaker:VolumeKmsKey" = "true" } }
      },
      {
        Sid       = "DenySageMakerTrainingJobWithoutVolumeKMS"
        Effect    = "Deny"
        Action    = "sagemaker:CreateTrainingJob"
        Resource  = "*"
        Condition = { Null = { "sagemaker:VolumeKmsKey" = "true" } }
      },
      {
        Sid       = "DenySageMakerTrainingJobWithoutOutputKMS"
        Effect    = "Deny"
        Action    = "sagemaker:CreateTrainingJob"
        Resource  = "*"
        Condition = { Null = { "sagemaker:OutputKmsKey" = "true" } }
      },
    ]
  })

  policies = {
    deny-disable-bedrock-logging-and-guardrails = {
      enabled     = var.enable_deny_disable_bedrock_logging_and_guardrails
      description = "Denies disabling Bedrock model invocation logging or deleting Bedrock Guardrails."
      content     = local.deny_disable_bedrock_logging_and_guardrails_content
    }
    restrict-bedrock-foundation-models = {
      enabled     = var.enable_restrict_bedrock_foundation_models
      description = "Restricts Bedrock model invocation to an allow-listed set of foundation models."
      content     = local.restrict_bedrock_foundation_models_content
    }
    lockdown-sagemaker-notebooks = {
      enabled     = var.enable_lockdown_sagemaker_notebooks
      description = "Denies SageMaker notebook instances with direct internet access, root access, or no VPC."
      content     = local.lockdown_sagemaker_notebooks_content
    }
    require-sagemaker-encryption = {
      enabled     = var.enable_require_sagemaker_encryption
      description = "Denies SageMaker notebook instances and training jobs that don't specify a KMS key."
      content     = local.require_sagemaker_encryption_content
    }
  }

  enabled_policies = { for name, p in local.policies : name => p if p.enabled }

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
