output "lambda_function_arn" {
  description = "ARN of the remediation Lambda function."
  value       = aws_lambda_function.remediate.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for remediation notifications."
  value       = aws_sns_topic.remediation.arn
}

output "config_rule_name" {
  description = "Name of the AWS Config rule."
  value       = aws_config_config_rule.restricted_ports.name
}

output "log_encryption_key_arn" {
  description = "ARN of the KMS key encrypting the Lambda's log group and environment variables."
  value       = aws_kms_key.log_encryption.arn
}
