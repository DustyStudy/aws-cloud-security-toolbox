output "trail_arn" {
  description = "ARN of the Organization trail."
  value       = aws_cloudtrail.organization.arn
}

output "trail_bucket_name" {
  description = "Name of the S3 bucket holding trail logs for every account in the Organization."
  value       = aws_s3_bucket.trail.id
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic CloudTrail publishes new-log-file notifications to."
  value       = aws_sns_topic.trail.arn
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch Logs group receiving trail events, for metric filters and alarms."
  value       = aws_cloudwatch_log_group.trail.name
}
