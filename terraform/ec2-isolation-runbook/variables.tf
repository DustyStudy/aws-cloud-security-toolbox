variable "name_prefix" {
  type        = string
  description = "Prefix used for naming all resources created by this module."
  default     = "ec2-isolation"
}

variable "vpc_id" {
  type        = string
  description = "VPC to create the isolation security group in. Use one module instance per VPC you want this available for."
}

variable "notification_email" {
  type        = string
  description = "Optional email address to subscribe to the SNS topic. Leave empty to skip."
  default     = ""
}
