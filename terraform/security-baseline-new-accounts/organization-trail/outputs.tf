output "trail_arn" {
  description = "ARN of the Organization trail."
  value       = aws_cloudtrail.organization.arn
}

output "trail_bucket_name" {
  description = "Name of the S3 bucket holding trail logs for every account in the Organization."
  value       = aws_s3_bucket.trail.id
}
