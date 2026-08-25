data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_security_group" "isolation" {
  # checkov:skip=CKV2_AWS_5: This SG is deliberately unattached until an
  # incident - it's a spare, fully-locked-down group the runbook swaps
  # onto a compromised instance at isolation time via ModifyInstanceAttribute.
  name_prefix = "${var.name_prefix}-isolation-"
  description = "Fully isolated SG for incident-response quarantine - no inbound, no outbound."
  vpc_id      = var.vpc_id

  egress {
    description = "Placeholder rule required to override the default allow-all-outbound rule - effectively blocks all egress."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["127.0.0.1/32"]
  }

  tags = {
    Purpose = "incident-response-isolation"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_sns_topic" "isolation" {
  name              = "${var.name_prefix}-isolation-notifications"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.isolation.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_iam_role" "automation" {
  name = "${var.name_prefix}-isolation-automation-role"

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
  name = "${var.name_prefix}-isolation-policy"
  role = aws_iam_role.automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read-only, EC2 doesn't support resource-level scoping for Describe.
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ec2:CreateSnapshot", "ec2:CreateTags"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:snapshot/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:ModifyInstanceAttribute", "ec2:StopInstances"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.isolation.arn
      },
    ]
  })
}

resource "aws_ssm_document" "isolation_runbook" {
  name            = "${var.name_prefix}-IsolateCompromisedInstance"
  document_type   = "Automation"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "0.3"
    description   = "Isolates a suspected-compromised EC2 instance for incident response."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      InstanceId = {
        type        = "String"
        description = "The instance to isolate."
      }
      IncidentId = {
        type        = "String"
        description = "Optional ticket/incident reference, used to tag the instance and snapshots."
        default     = "unspecified"
      }
      StopInstance = {
        type          = "String"
        description   = "Whether to also stop the instance after isolating its network access."
        default       = "false"
        allowedValues = ["true", "false"]
      }
      IsolationSecurityGroupId = {
        type        = "String"
        description = "The isolation security group to apply."
        default     = aws_security_group.isolation.id
      }
      NotificationTopicArn = {
        type        = "String"
        description = "SNS topic to notify once isolation is complete."
        default     = aws_sns_topic.isolation.arn
      }
      AutomationAssumeRole = {
        type        = "String"
        description = "IAM role ARN used by SSM Automation to execute this document."
        default     = aws_iam_role.automation.arn
      }
    }
    mainSteps = [
      {
        name   = "TagInstanceForIsolation"
        action = "aws:createTags"
        inputs = {
          ResourceType = "EC2"
          ResourceIds  = ["{{ InstanceId }}"]
          Tags = [
            { Key = "IsolatedForIR", Value = "true" },
            { Key = "IsolationTimestamp", Value = "{{ global:DATE_TIME }}" },
            { Key = "IsolationIncidentId", Value = "{{ IncidentId }}" },
          ]
        }
      },
      {
        name   = "SnapshotAttachedVolumes"
        action = "aws:executeScript"
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          InputPayload = {
            InstanceId = "{{ InstanceId }}"
            IncidentId = "{{ IncidentId }}"
          }
          Script = file("${path.module}/scripts/snapshot_attached_volumes.py")
        }
        outputs = [
          { Name = "SnapshotIds", Selector = "$.Payload.SnapshotIds", Type = "StringList" }
        ]
      },
      {
        name   = "ApplyIsolationSecurityGroup"
        action = "aws:executeAwsApi"
        inputs = {
          Service    = "ec2"
          Api        = "ModifyInstanceAttribute"
          InstanceId = "{{ InstanceId }}"
          Groups     = ["{{ IsolationSecurityGroupId }}"]
        }
      },
      {
        name   = "CheckIfShouldStop"
        action = "aws:branch"
        inputs = {
          Choices = [
            { NextStep = "StopInstanceStep", Variable = "{{ StopInstance }}", StringEquals = "true" }
          ]
          Default = "NotifyStep"
        }
      },
      {
        name   = "StopInstanceStep"
        action = "aws:executeAwsApi"
        inputs = {
          Service     = "ec2"
          Api         = "StopInstances"
          InstanceIds = ["{{ InstanceId }}"]
        }
      },
      {
        name   = "NotifyStep"
        action = "aws:executeAwsApi"
        isEnd  = true
        inputs = {
          Service  = "sns"
          Api      = "Publish"
          TopicArn = "{{ NotificationTopicArn }}"
          Subject  = "EC2 instance {{ InstanceId }} isolated for incident response"
          Message  = <<-EOT
            Instance {{ InstanceId }} was tagged, had its attached volumes
            snapshotted (see the SnapshotAttachedVolumes step output for
            snapshot IDs), and had its security groups replaced with the
            isolation group {{ IsolationSecurityGroupId }}. StopInstance
            was set to {{ StopInstance }}. Incident reference: {{ IncidentId }}.
          EOT
        }
      },
    ]
  })
}
