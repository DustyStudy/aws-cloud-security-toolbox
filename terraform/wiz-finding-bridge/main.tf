data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/wiz_webhook_bridge.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "random_password" "webhook_secret" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "webhook_secret" {
  # checkov:skip=CKV2_AWS_57: this secret is a static token embedded in
  # the webhook URL pasted into Wiz's console, not a rotatable service
  # credential - automatic rotation would silently break the Wiz
  # integration until someone manually re-pastes the new URL. Rotate
  # manually (re-run the secret retrieval command in the README, update
  # it in Wiz) if you suspect exposure.
  name        = "${var.name_prefix}-wiz-webhook-secret"
  description = "Long random token that must appear as the last path segment of the webhook URL pasted into Wiz's Webhook integration. See the module README."
}

resource "aws_secretsmanager_secret_version" "webhook_secret" {
  secret_id     = aws_secretsmanager_secret.webhook_secret.id
  secret_string = random_password.webhook_secret.result
}

resource "aws_sns_topic" "audit" {
  name              = "${var.name_prefix}-wiz-finding-bridge"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.audit.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_kms_key" "log_encryption" {
  description         = "Encrypts the ${var.name_prefix} Wiz finding bridge Lambda's log group and API Gateway access log group."
  enable_key_rotation = true

  policy = jsonencode({
    Version   = "2012-10-17"
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
        Principal = { Service = "logs.${data.aws_region.current.region}.amazonaws.com" }
        Action    = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role" "lambda_exec" {
  name = "${var.name_prefix}-wiz-finding-bridge-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_exec" {
  name = "${var.name_prefix}-wiz-finding-bridge-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.webhook_secret.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.audit.arn
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

resource "aws_iam_role_policy" "remediation_invoke" {
  count = length(var.remediation_lambda_arns) > 0 ? 1 : 0
  name  = "${var.name_prefix}-remediation-invoke"
  role  = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = var.remediation_lambda_arns
      },
    ]
  })
}

resource "aws_lambda_function" "bridge" {
  # checkov:skip=CKV_AWS_117: Control-plane only Lambda (Secrets Manager/
  # SNS/Lambda APIs over public AWS endpoints) - no customer VPC
  # resources touched.
  function_name                  = "${var.name_prefix}-wiz-webhook-bridge"
  description                    = "Bridges Wiz webhook findings into SNS and, optionally, this repo's own remediation Lambdas."
  role                           = aws_iam_role.lambda_exec.arn
  handler                        = "wiz_webhook_bridge.lambda_handler"
  runtime                        = "python3.12"
  timeout                        = 30
  memory_size                    = 256
  reserved_concurrent_executions = 5
  filename                       = data.archive_file.lambda_zip.output_path
  source_code_hash               = data.archive_file.lambda_zip.output_base64sha256
  kms_key_arn                    = aws_kms_key.log_encryption.arn
  code_signing_config_arn        = var.code_signing_config_arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      SNS_TOPIC_ARN          = aws_sns_topic.audit.arn
      WEBHOOK_SECRET_ARN     = aws_secretsmanager_secret.webhook_secret.arn
      MIN_SEVERITY           = var.minimum_severity
      SEVERITY_FIELD_PATH    = var.severity_field_path
      TITLE_FIELD_PATH       = var.title_field_path
      RESOURCE_FIELD_PATH    = var.resource_field_path
      REMEDIATION_LAMBDA_MAP = jsonencode(var.remediation_lambda_mapping)
    }
  }
}

resource "aws_cloudwatch_log_group" "bridge" {
  name              = "/aws/lambda/${aws_lambda_function.bridge.function_name}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.log_encryption.arn
}

resource "aws_apigatewayv2_api" "wiz_webhook" {
  name          = "${var.name_prefix}-wiz-webhook"
  protocol_type = "HTTP"
  description   = "Receives Wiz webhook deliveries and forwards them to the bridge Lambda."
}

resource "aws_apigatewayv2_integration" "bridge" {
  api_id                 = aws_apigatewayv2_api.wiz_webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.bridge.arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

resource "aws_apigatewayv2_route" "bridge" {
  # checkov:skip=CKV_AWS_59: intentionally no IAM/JWT authorizer here -
  # this endpoint authenticates the caller via an unguessable secret path
  # segment instead, matching the only configuration surface Wiz's basic
  # Webhook integration exposes (a destination URL, no custom headers).
  # See the module README.
  api_id    = aws_apigatewayv2_api.wiz_webhook.id
  route_key = "POST /wiz-webhook/{secretToken}"
  target    = "integrations/${aws_apigatewayv2_integration.bridge.id}"
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.name_prefix}-wiz-webhook"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.log_encryption.arn
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.wiz_webhook.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    # Deliberately excludes the request body from the access log line
    # (it can contain finding details) - only metadata about the call.
    format = jsonencode({
      requestId               = "$context.requestId"
      ip                      = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    throttling_burst_limit = var.throttle_burst_limit
    throttling_rate_limit  = var.throttle_rate_limit
  }
}

resource "aws_lambda_permission" "allow_apigateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bridge.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.wiz_webhook.execution_arn}/*/*/wiz-webhook/*"
}
