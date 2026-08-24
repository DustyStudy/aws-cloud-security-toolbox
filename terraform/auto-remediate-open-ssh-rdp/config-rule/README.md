# Auto-Remediate Open SSH/RDP — AWS Config Rule (Terraform)

Continuous-compliance path: an AWS Config managed rule
(`RESTRICTED_INCOMING_TRAFFIC`) evaluates every in-scope security group,
flagging any with **SSH (22)** or **RDP (3389)** open to the internet. An
SSM Automation document then invokes the shared remediation Lambda to
revoke the offending rule.

## How it works

1. AWS Config evaluates all `AWS::EC2::SecurityGroup` resources against
   the managed rule on the configured schedule and on change.
2. Non-compliant groups trigger the attached auto-remediation, which runs
   this module's SSM Automation document.
3. That document invokes the same `remediate_open_ssh_rdp.py` Lambda used
   by the event-driven module, passing the non-compliant security group's
   ID.
4. The Lambda revokes any matching rule and publishes an SNS notification.

This catches security groups that were already open before this module
was applied, and drift that slips past the event-driven path.

Also included for defense-in-depth / hygiene: a customer-managed KMS key
encrypting the Lambda's log group and environment variables, a dead-letter
SQS queue for failed async invocations, and a reserved concurrency limit
(5) so this function can't consume the account's shared Lambda concurrency
pool.

## Prerequisites

**AWS Config must already be enabled** in the account/region (a
configuration recorder + delivery channel). This module assumes that's
already set up — most accounts running compliance tooling already have
it on. If not, add `aws_config_configuration_recorder` and
`aws_config_delivery_channel` resources first.

## Usage

```hcl
module "sg_auto_remediate_config" {
  source = "github.com/DustyStudy/aws-cloud-security-toolbox//terraform/auto-remediate-open-ssh-rdp/config-rule"

  name_prefix                 = "sg-config-remediate"
  notification_email          = "you@example.com"
  maximum_execution_frequency = "TwentyFour_Hours"
}
```

Requires the `hashicorp/archive` provider in addition to `hashicorp/aws`.
Works unmodified in AWS commercial and GovCloud.

## Inputs

| Name | Description | Default |
|---|---|---|
| `name_prefix` | Prefix for all resource names | `sg-config-remediate` |
| `notification_email` | Email to subscribe to the SNS topic (optional) | `""` |
| `maximum_execution_frequency` | How often Config re-evaluates all groups | `TwentyFour_Hours` |

## Outputs

| Name | Description |
|---|---|
| `lambda_function_arn` | ARN of the remediation Lambda |
| `sns_topic_arn` | ARN of the SNS notification topic |
| `config_rule_name` | Name of the AWS Config rule |

## Notes

- Deploy this **alongside** the `../event-driven/` module for both
  real-time revocation and periodic drift-catching — each provisions its
  own Lambda, so they're fully independent.
- Auto-remediation retries up to 3 times, 60 seconds apart, before
  leaving the resource flagged non-compliant for manual review.
