variable "name_prefix" {
  type        = string
  description = "Prefix used for naming all resources created by this module."
  default     = "iam-credential-hygiene"
}

variable "notification_email" {
  type        = string
  description = "Optional email address to subscribe to the SNS topic. Leave empty to skip."
  default     = ""
}

variable "max_key_age_days" {
  type        = number
  description = "Deactivate any active key older than this many days, regardless of use."
  default     = 180
}

variable "max_unused_days" {
  type        = number
  description = "Deactivate any active key not used in this many days (or never used and older than this many days)."
  default     = 90
}

variable "schedule_expression" {
  type        = string
  description = "EventBridge schedule expression controlling how often the scan runs."
  default     = "rate(1 day)"
}

variable "exempt_tag_key" {
  type        = string
  description = "Optional IAM user tag key. Users carrying this tag are skipped entirely. Leave empty to check every user."
  default     = ""
}

variable "exempt_tag_value" {
  type        = string
  description = "Optional value exempt_tag_key must match. Leave empty to exempt on the tag key's presence alone."
  default     = ""
}

variable "code_signing_config_arn" {
  type        = string
  description = <<-EOT
    Optional ARN of an existing aws_lambda_code_signing_config to enforce
    code-signature validation on this function. Leave null to skip.
  EOT
  default     = null
}
