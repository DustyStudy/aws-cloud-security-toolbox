variable "name_prefix" {
  type        = string
  description = "Prefix used when naming the StackSet."
  default     = "security-baseline"
}

variable "target_organizational_unit_ids" {
  type        = list(string)
  description = "OU ID(s) to deploy the baseline to. Every account in these OUs - present and future - gets the baseline."
}

variable "regions" {
  type        = list(string)
  description = "Region(s) to enable the baseline in within each account. AWS Config and GuardDuty are regional - list every region you operate in."
  default     = ["us-east-1"]
}

variable "call_as" {
  type        = string
  description = "SELF if applying from the Organizations management account, DELEGATED_ADMIN if applying from a registered delegated administrator account instead."
  default     = "SELF"

  validation {
    condition     = contains(["SELF", "DELEGATED_ADMIN"], var.call_as)
    error_message = "call_as must be either SELF or DELEGATED_ADMIN."
  }
}
