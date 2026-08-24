variable "name_prefix" {
  type        = string
  description = "Prefix used for naming all resources created by this module."
  default     = "sg-config-remediate"
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

variable "maximum_execution_frequency" {
  type        = string
  description = "How often AWS Config re-evaluates all security groups against this rule."
  default     = "TwentyFour_Hours"

  validation {
    condition = contains(
      ["One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"],
      var.maximum_execution_frequency
    )
    error_message = "maximum_execution_frequency must be one of One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours."
  }
}
