data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/remediate_open_ssh_rdp.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_sns_topic" "remediation" {
  name              = "${var.name_prefix}-sg-remediation-notifications"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.remediation.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-remediation-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600 # 14 days - time to notice and investigate a failed remediation
}

resource "aws_kms_key" "log_encryption" {
  description         = "Encrypts the ${var.name_prefix} remediation Lambda's log group and environment variables."
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
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-remediate-open-ssh-rdp"
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "log_encryption" {
  name          = "alias/${var.name_prefix}-remediate-ssh-rdp"
  target_key_id = aws_kms_key.log_encryption.key_id
}

resource "aws_iam_role" "lambda_exec" {
  name = "${var.name_prefix}-remediate-ssh-rdp-role"

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
  name = "${var.name_prefix}-remediate-ssh-rdp-policy"
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
        # Describe is a read-only action and EC2 does not support
        # resource-level permissions for it - "*" is required here.
        Effect   = "Allow"
        Action   = ["ec2:DescribeSecurityGroups"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:RevokeSecurityGroupIngress"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:security-group/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.remediation.arn
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
        # X-Ray does not support resource-level permissions for these actions.
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "remediate" {
  # checkov:skip=CKV_AWS_117: Control-plane only Lambda (EC2/SNS/SQS APIs over
  # public AWS endpoints, no customer VPC resources touched) - a VPC would add
  # NAT gateway/VPC endpoint cost and complexity with no security benefit here.
  function_name                  = "${var.name_prefix}-remediate-open-ssh-rdp"
  description                    = "Revokes SG ingress rules that open 22/3389 to the internet."
  role                           = aws_iam_role.lambda_exec.arn
  handler                        = "remediate_open_ssh_rdp.lambda_handler"
  runtime                        = "python3.12"
  timeout                        = 30
  memory_size                    = 128
  reserved_concurrent_executions = 5
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
      SNS_TOPIC_ARN = aws_sns_topic.remediation.arn
    }
  }
}

resource "aws_cloudwatch_log_group" "remediate" {
  name              = "/aws/lambda/${aws_lambda_function.remediate.function_name}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.log_encryption.arn
}

resource "aws_iam_role" "automation" {
  name = "${var.name_prefix}-ssm-automation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "automation" {
  name = "${var.name_prefix}-invoke-remediation-lambda"
  role = aws_iam_role.automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.remediate.arn
    }]
  })
}

resource "aws_ssm_document" "remediation" {
  name            = "${var.name_prefix}-RemediateOpenSSHRDP"
  document_type   = "Automation"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "0.3"
    description   = "Invokes the remediation Lambda for a non-compliant security group."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      SecurityGroupId = {
        type        = "String"
        description = "The non-compliant security group ID (Config passes this as RESOURCE_ID)."
      }
      AutomationAssumeRole = {
        type        = "String"
        description = "IAM role ARN used by SSM Automation to execute this document."
      }
    }
    mainSteps = [{
      name   = "InvokeRemediationLambda"
      action = "aws:invokeLambdaFunction"
      inputs = {
        FunctionName = aws_lambda_function.remediate.function_name
        InputPayload = {
          security_group_id = "{{ SecurityGroupId }}"
        }
      }
    }]
  })
}

resource "aws_config_config_rule" "restricted_ports" {
  name        = "${var.name_prefix}-restricted-ssh-rdp"
  description = "Flags security groups that allow unrestricted inbound access to SSH (22) or RDP (3389)."

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  input_parameters = jsonencode({
    blockedPort1 = "22"
    blockedPort2 = "3389"
  })

  maximum_execution_frequency = var.maximum_execution_frequency

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }
}

resource "aws_config_remediation_configuration" "auto_remediate" {
  config_rule_name           = aws_config_config_rule.restricted_ports.name
  resource_type              = "AWS::EC2::SecurityGroup"
  target_type                = "SSM_DOCUMENT"
  target_id                  = aws_ssm_document.remediation.name
  automatic                  = true
  maximum_automatic_attempts = 3
  retry_attempt_seconds      = 60

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.automation.arn
  }

  parameter {
    name           = "SecurityGroupId"
    resource_value = "RESOURCE_ID"
  }
}
