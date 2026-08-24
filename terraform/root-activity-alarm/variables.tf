variable "name_prefix" {
  type        = string
  description = "Prefix used for naming all resources created by this module."
  default     = "root-activity-alarm"
}

variable "notification_email" {
  type        = string
  description = "Optional email address to subscribe to the SNS topic. Leave empty to skip."
  default     = ""
}
