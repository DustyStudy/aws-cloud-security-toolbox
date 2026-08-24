variable "trail_name" {
  type        = string
  description = "Name for the organization trail (also used to derive the S3 bucket name)."
  default     = "organization-trail"
}

variable "organization_id" {
  type        = string
  description = <<-EOT
    Optional AWS Organization ID (e.g. o-abc123xyz0). If set, member
    accounts across the org are granted kms:Decrypt on the trail's KMS
    key (needed if they'll query their own logs directly, e.g. via
    Athena). Leave empty to restrict decryption to this account only.
  EOT
  default     = ""
}

variable "log_retention_days" {
  type        = number
  description = "Days before trail logs expire from the S3 bucket."
  default     = 2555 # ~7 years
}
