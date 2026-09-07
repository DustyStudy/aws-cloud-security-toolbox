variable "name_prefix" {
  type        = string
  description = "Prefix used for naming all resources created by this module."
  default     = "wiz-finding-bridge"
}

variable "notification_email" {
  type        = string
  description = "Optional email address to subscribe to the SNS topic. Leave empty to skip."
  default     = ""
}

variable "minimum_severity" {
  type        = string
  description = <<-EOT
    Lowest severity to notify on: CRITICAL, HIGH, MEDIUM, LOW, or
    INFORMATIONAL. A finding whose severity can't be resolved from
    severity_field_path is always notified regardless of this setting
    (fails open, not silent).
  EOT
  default     = "HIGH"

  validation {
    condition     = contains(["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL"], var.minimum_severity)
    error_message = "minimum_severity must be one of CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL."
  }
}

variable "severity_field_path" {
  type        = string
  description = "Dot-notation path to the severity field in the Wiz webhook payload."
  default     = "severity"
}

variable "title_field_path" {
  type        = string
  description = "Dot-notation path to a human-readable title/rule-name field in the payload."
  default     = "title"
}

variable "resource_field_path" {
  type        = string
  description = <<-EOT
    Dot-notation path to a resource object/identifier field in the
    payload. Defaults to "primaryResource", an object in Wiz's schema -
    rendered as JSON in the report since its internal shape isn't
    assumed.
  EOT
  default     = "primaryResource"
}

variable "remediation_lambda_mapping" {
  type        = map(string)
  description = <<-EOT
    Map of a title value (as resolved by title_field_path) to a Lambda
    function ARN to invoke with the normalized finding. Every ARN used
    here must also appear in remediation_lambda_arns so the execution
    role is actually granted permission to invoke it. Default {} (notify
    only, no forwarding).
  EOT
  default     = {}
}

variable "remediation_lambda_arns" {
  type        = list(string)
  description = <<-EOT
    ARNs of Lambda functions this bridge is allowed to invoke (must match
    the values used in remediation_lambda_mapping). Leave empty if you're
    only using this module to notify, not to trigger remediation.
  EOT
  default     = []
}

variable "code_signing_config_arn" {
  type        = string
  description = "Optional ARN of an existing aws_lambda_code_signing_config to enforce on this function. Leave null to skip."
  default     = null
}

variable "throttle_burst_limit" {
  type        = number
  description = "API Gateway stage-level burst limit for the webhook route."
  default     = 10
}

variable "throttle_rate_limit" {
  type        = number
  description = "API Gateway stage-level steady-state requests-per-second limit."
  default     = 5
}
