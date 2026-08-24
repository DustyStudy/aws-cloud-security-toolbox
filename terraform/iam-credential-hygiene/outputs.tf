output "lambda_function_arn" {
  description = "ARN of the IAM hygiene Lambda function."
  value       = aws_lambda_function.hygiene.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for deactivation notifications."
  value       = aws_sns_topic.hygiene.arn
}
