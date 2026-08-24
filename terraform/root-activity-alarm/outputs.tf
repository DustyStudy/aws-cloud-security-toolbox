output "sns_topic_arn" {
  description = "ARN of the SNS topic receiving root activity alerts."
  value       = aws_sns_topic.root_activity.arn
}

output "event_rule_arn" {
  description = "ARN of the EventBridge rule watching for root activity."
  value       = aws_cloudwatch_event_rule.root_activity.arn
}
