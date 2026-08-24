output "lambda_function_arn" {
  description = "ARN of the remediation Lambda function."
  value       = aws_lambda_function.remediate.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for remediation notifications."
  value       = aws_sns_topic.remediation.arn
}

output "event_rule_arn" {
  description = "ARN of the EventBridge rule watching for AuthorizeSecurityGroupIngress."
  value       = aws_cloudwatch_event_rule.authorize_sg_ingress.arn
}
