variable "name_prefix" {
  type        = string
  description = "Prefix used for naming all resources created by this module (also the ECR repository, ECS cluster/service, and RDS identifier)."
  default     = "claude-gateway"
}

variable "vpc_id" {
  type        = string
  description = "VPC to deploy the gateway into. Must already have outbound internet access via a NAT gateway."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "At least two private subnets in different Availability Zones. Used for the ALB, the ECS service, the RDS instance, and (if enabled) the Bedrock VPC endpoint."
}

variable "corporate_cidr" {
  type        = string
  description = "CIDR range allowed to reach the gateway's ALB on 443 (your corporate network / VPN range)."
}

variable "acm_certificate_arn" {
  type        = string
  description = "ARN of an ACM certificate (imported or issued via AWS Private CA) for the gateway's internal hostname."
}

variable "container_image_tag" {
  type        = string
  description = "Tag of the gateway image already pushed to this module's ECR repository. The image must exist before the ECS service can start - see this module's README for the two-phase apply."
  default     = "latest"
}

variable "desired_count" {
  type        = number
  description = "Number of gateway tasks to run. The gateway is stateless; scale horizontally for availability."
  default     = 1
}

variable "db_instance_class" {
  type        = string
  description = "RDS instance class for the gateway's PostgreSQL store."
  default     = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  type        = number
  description = "Allocated storage (GB) for the RDS instance."
  default     = 20
}

variable "enable_deletion_protection" {
  type        = bool
  description = "RDS deletion protection. Set to false only for throwaway/test deployments - when true, a final snapshot is taken on destroy instead of skipped."
  default     = true
}

variable "oidc_client_secret_value" {
  type        = string
  description = "The OAuth client secret from your IdP's gateway application registration. Stored in Secrets Manager."
  sensitive   = true
}

variable "create_bedrock_vpc_endpoint" {
  type        = bool
  description = "Create an interface VPC endpoint for bedrock-runtime so inference traffic never leaves the AWS network (recommended). Requires PrivateDnsEnabled support in your VPC."
  default     = true
}
