resource "aws_sns_topic" "root_activity" {
  name              = "${var.name_prefix}-root-activity-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.root_activity.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_cloudwatch_event_rule" "root_activity" {
  name        = "${var.name_prefix}-root-activity"
  description = "Matches any CloudTrail event performed as the root user."

  event_pattern = jsonencode({
    detail-type = [
      "AWS Console Sign In via CloudTrail",
      "AWS API Call via CloudTrail",
      "AWS Service Event via CloudTrail",
    ]
    detail = {
      userIdentity = {
        type = ["Root"]
      }
    }
  })
}

resource "aws_sns_topic_policy" "root_activity" {
  arn = aws_sns_topic.root_activity.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.root_activity.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.root_activity.arn }
      }
    }]
  })
}

resource "aws_cloudwatch_event_target" "root_activity" {
  rule = aws_cloudwatch_event_rule.root_activity.name
  arn  = aws_sns_topic.root_activity.arn

  input_transformer {
    input_paths = {
      account     = "$.account"
      region      = "$.region"
      time        = "$.time"
      eventName   = "$.detail.eventName"
      eventSource = "$.detail.eventSource"
      sourceIP    = "$.detail.sourceIPAddress"
    }
    input_template = "\"Root user activity detected in account <account> (<region>) at <time>: <eventSource> <eventName> from <sourceIP>. Investigate immediately if this wasn't expected.\""
  }
}
