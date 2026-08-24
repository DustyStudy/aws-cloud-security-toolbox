# Auto-Remediate Open SSH/RDP — Event-Driven (Terraform)

Revokes security group ingress rules that open **SSH (22)** or **RDP (3389)**
to `0.0.0.0/0` / `::/0`, within seconds of the rule being created.

## How it works

1. Someone calls `AuthorizeSecurityGroupIngress` and opens 22 or 3389 to the
   internet.
2. CloudTrail delivers that management event to EventBridge's default
   event bus automatically — no dedicated trail resource required.
3. An `aws_cloudwatch_event_rule` matches on
   `eventName: AuthorizeSecurityGroupIngress` and invokes a Lambda.
4. The Lambda inspects exactly the rule(s) just added and revokes any that
   match the risky pattern, then publishes an SNS notification.

Pair this with the sibling `../config-rule/` module to also catch
pre-existing open rules and drift on a schedule.

Also included for defense-in-depth / hygiene: a customer-managed KMS key
encrypting the Lambda's log group and environment variables, a dead-letter
SQS queue for failed async invocations, and a reserved concurrency limit
(5) so this function can't consume the account's shared Lambda concurrency
pool. X-Ray tracing is on, log retention is 365 days, and there's an
optional code-signing-config hook for accounts that enforce Lambda code
signing.

## Usage

```hcl
module "sg_auto_remediate_event_driven" {
  source = "github.com/DustyStudy/aws-cloud-security-toolbox//terraform/auto-remediate-open-ssh-rdp/event-driven"

  name_prefix         = "sg-auto-remediate"
  notification_email  = "you@example.com"
}
```

Requires the `hashicorp/archive` provider (used to zip the Lambda source
from `../lambda/remediate_open_ssh_rdp.py` at plan/apply time) in addition
to `hashicorp/aws`.

Works unmodified in AWS commercial and GovCloud — no partition is
hardcoded; ARNs are built from `data.aws_partition.current.partition`.

## Inputs

| Name | Description | Default |
|---|---|---|
| `name_prefix` | Prefix for all resource names | `sg-auto-remediate` |
| `notification_email` | Email to subscribe to the SNS topic (optional) | `""` |
| `code_signing_config_arn` | ARN of an existing `aws_lambda_code_signing_config` to enforce (optional) | `null` |

## Outputs

| Name | Description |
|---|---|
| `lambda_function_arn` | ARN of the remediation Lambda |
| `sns_topic_arn` | ARN of the SNS notification topic |
| `event_rule_arn` | ARN of the EventBridge rule |

## Testing it

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp --port 22 --cidr 0.0.0.0/0
```

The rule should be revoked within a few seconds — check the Lambda's
CloudWatch Logs and your inbox (if `notification_email` was set).
