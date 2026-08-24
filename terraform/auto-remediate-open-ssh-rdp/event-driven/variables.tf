variable "name_prefix" {
  type        = string
  description = "Prefix used for naming all resources created by this module."
  default     = "sg-auto-remediate"
}

variable "notification_email" {
  type        = string
  description = "Optional email address to subscribe to the SNS remediation topic. Leave empty to skip."
  default     = ""
}

variable "code_signing_config_arn" {
  type        = string
  description = <<-EOT
    Optional ARN of an existing aws_lambda_code_signing_config to enforce
    code-signature validation on this function. Leave null to skip (most
    accounts don't have a signing pipeline set up; set this if yours does
    and requires it).
  EOT
  default     = null
}
