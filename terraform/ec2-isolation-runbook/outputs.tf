output "runbook_name" {
  description = "Name of the SSM Automation document - run it via the console (Systems Manager > Automation) or `aws ssm start-automation-execution`."
  value       = aws_ssm_document.isolation_runbook.name
}

output "isolation_security_group_id" {
  description = "ID of the isolation security group."
  value       = aws_security_group.isolation.id
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for isolation notifications."
  value       = aws_sns_topic.isolation.arn
}
