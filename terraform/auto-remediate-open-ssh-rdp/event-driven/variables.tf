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
