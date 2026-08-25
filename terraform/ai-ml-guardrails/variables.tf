variable "name_prefix" {
  type        = string
  description = "Prefix used when naming each SCP in Organizations."
  default     = "ai-ml-guardrail"
}

variable "target_ids" {
  type        = list(string)
  description = "OU IDs, account IDs, and/or the org root ID to attach every enabled policy to."
}

variable "enable_deny_disable_bedrock_logging_and_guardrails" {
  type        = bool
  description = "Deny disabling Bedrock model invocation logging or deleting Bedrock Guardrails."
  default     = true
}

variable "enable_restrict_bedrock_foundation_models" {
  type        = bool
  description = <<-EOT
    Restrict bedrock:InvokeModel/InvokeModelWithResponseStream to an
    allow-listed set of foundation models. Off by default - review
    allowed_bedrock_model_patterns before enabling, or every model
    invocation in the account will be denied.
  EOT
  default     = false
}

variable "allowed_bedrock_model_patterns" {
  type        = list(string)
  description = "Foundation-model ID patterns permitted when enable_restrict_bedrock_foundation_models is true (matched against arn:*:bedrock:*::foundation-model/<pattern>)."
  default     = ["anthropic.claude*", "amazon.titan*"]
}

variable "enable_lockdown_sagemaker_notebooks" {
  type        = bool
  description = "Deny SageMaker notebook instances with direct internet access, root access, or no VPC."
  default     = true
}

variable "enable_require_sagemaker_encryption" {
  type        = bool
  description = "Deny SageMaker notebook instances and training jobs that don't specify a KMS key."
  default     = true
}
