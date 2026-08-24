variable "name_prefix" {
  type        = string
  description = "Prefix used when naming each SCP in Organizations."
  default     = "guardrail"
}

variable "target_ids" {
  type        = list(string)
  description = "OU IDs, account IDs, and/or the org root ID to attach every enabled policy to."
}

variable "enable_deny_root_user" {
  type        = bool
  description = "Deny all actions taken as the root user."
  default     = true
}

variable "enable_deny_disable_security_services" {
  type        = bool
  description = "Deny disabling CloudTrail, Config, GuardDuty, or Security Hub."
  default     = true
}

variable "enable_require_imdsv2" {
  type        = bool
  description = "Deny launching or modifying EC2 instances without IMDSv2 required."
  default     = true
}

variable "enable_deny_leave_organization" {
  type        = bool
  description = "Deny member accounts from leaving the Organization."
  default     = true
}

variable "enable_deny_disable_s3_public_access_block" {
  type        = bool
  description = "Deny disabling S3 Block Public Access at the account or bucket level."
  default     = true
}

variable "enable_restrict_regions" {
  type        = bool
  description = "Deny actions outside allowed_regions (global services exempted). Off by default - review allowed_regions before enabling."
  default     = false
}

variable "allowed_regions" {
  type        = list(string)
  description = "Regions permitted when enable_restrict_regions is true (e.g. [\"us-gov-west-1\", \"us-gov-east-1\"] for GovCloud)."
  default     = ["us-east-1"]
}
