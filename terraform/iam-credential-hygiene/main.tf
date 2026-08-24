data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/deactivate_stale_iam_keys.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_sns_topic" "hygiene" {
  name              = "${var.name_prefix}-iam-key-deactivations"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.hygiene.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-hygiene-dlq"
  kms_master_key_id         = "alias/aws/sqs"
  message_retention_seconds = 1209600
}

resource "aws_kms_key" "log_encryption" {
  description         = "Encrypts the ${var.name_prefix} IAM hygiene Lambda's log group and environment variables."
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogsUseOfKey"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-deactivate-stale-iam-keys"
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "log_encryption" {
  name          = "alias/${var.name_prefix}-iam-hygiene"
  target_key_id = aws_kms_key.log_encryption.key_id
}

resource "aws_iam_role" "lambda_exec" {
  name = "${var.name_prefix}-iam-hygiene-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_exec" {
  name = "${var.name_prefix}-iam-hygiene-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        # Read-only, account-wide by nature - IAM doesn't support
        # resource-level scoping for listing across all users.
        Effect = "Allow"
        Action = [
          "iam:ListUsers",
          "iam:ListAccessKeys",
          "iam:GetAccessKeyLastUsed",
          "iam:ListUserTags",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:UpdateAccessKey"]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:user/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.hygiene.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource = aws_kms_key.log_encryption.arn
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "hygiene" {
  # checkov:skip=CKV_AWS_117: Control-plane only Lambda (IAM/SNS/SQS APIs
  # over public AWS endpoints) - no customer VPC resources touched.
  function_name                  = "${var.name_prefix}-deactivate-stale-iam-keys"
  description                    = "Deactivates stale/unused IAM access keys on a schedule."
  role                           = aws_iam_role.lambda_exec.arn
  handler                        = "deactivate_stale_iam_keys.lambda_handler"
  runtime                        = "python3.12"
  timeout                        = 120
  memory_size                    = 256
  reserved_concurrent_executions = 2
  filename                       = data.archive_file.lambda_zip.output_path
  source_code_hash               = data.archive_file.lambda_zip.output_base64sha256
  kms_key_arn                    = aws_kms_key.log_encryption.arn
  code_signing_config_arn        = var.code_signing_config_arn

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  environment {
    variables = {
      SNS_TOPIC_ARN    = aws_sns_topic.hygiene.arn
      MAX_KEY_AGE_DAYS = tostring(var.max_key_age_days)
      MAX_UNUSED_DAYS  = tostring(var.max_unused_days)
      EXEMPT_TAG_KEY   = var.exempt_tag_key
      EXEMPT_TAG_VALUE = var.exempt_tag_value
    }
  }
}

resource "aws_cloudwatch_log_group" "hygiene" {
  name              = "/aws/lambda/${aws_lambda_function.hygiene.function_name}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.log_encryption.arn
}

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${var.name_prefix}-schedule"
  description         = "Triggers the IAM credential hygiene scan on a schedule."
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "hygiene" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = aws_lambda_function.hygiene.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hygiene.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}
