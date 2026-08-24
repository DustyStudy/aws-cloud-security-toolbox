# Auto-Remediate Open SSH/RDP — AWS Config Rule (CloudFormation)

Continuous-compliance path: an AWS Config managed rule
(`RESTRICTED_INCOMING_TRAFFIC`) evaluates every security group in scope,
flagging any with **SSH (22)** or **RDP (3389)** open to the internet. A
built-in SSM Automation document then invokes the shared remediation
Lambda to revoke the offending rule.

## How it works

1. AWS Config evaluates all `AWS::EC2::SecurityGroup` resources against
   the managed rule on the schedule you set (`MaximumExecutionFrequency`),
   and also whenever a security group changes.
2. Non-compliant groups trigger the attached auto-remediation, which runs
   the SSM Automation document in this stack.
3. That document invokes the same `remediate_open_ssh_rdp.py` Lambda used
   by the event-driven template, passing the non-compliant security
   group's ID.
4. The Lambda describes the group, revokes any rule matching 22/3389 open
   to `0.0.0.0/0` or `::/0`, and publishes an SNS notification.

This catches security groups that were already open **before** this stack
existed, and any drift that slips past the event-driven path (e.g. changes
made via CloudFormation/Terraform directly rather than the EC2 API in a
way CloudTrail's event pattern would match, or while the event-driven
stack was temporarily disabled).

Also included for defense-in-depth / hygiene: a customer-managed KMS key
encrypting the Lambda's log group and environment variables, a dead-letter
SQS queue for failed async invocations, and a reserved concurrency limit
(5) so this function can't consume the account's shared Lambda concurrency
pool. X-Ray tracing is on, log retention is 365 days, and there's an
optional code-signing-config hook for accounts that enforce Lambda code
signing.

## Prerequisites

- **AWS Config must already be enabled** in the account/region (a
  configuration recorder + delivery channel). This template does not set
  Config up from scratch — most accounts running compliance tooling
  already have it on; if not, add an `AWS::Config::ConfigurationRecorder`
  and `AWS::Config::DeliveryChannel` first.

## Deploying

Package the Lambda the same way as the event-driven template:

```bash
cd ../lambda
zip lambda.zip remediate_open_ssh_rdp.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/auto-remediate-open-ssh-rdp/lambda.zip
```

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name sg-config-remediate-ssh-rdp \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      LambdaCodeS3Bucket=YOUR-BUCKET \
      NotificationEmail=you@example.com \
      MaximumExecutionFrequency=TwentyFour_Hours
```

Works the same way in GovCloud — deploy against a GovCloud profile/region;
all ARNs use `${AWS::Partition}`.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `LambdaCodeS3Bucket` | Yes | Bucket holding the packaged `lambda.zip` |
| `LambdaCodeS3Key` | No | Key of the zip (default `auto-remediate-open-ssh-rdp/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS remediation topic |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce on this Lambda |
| `MaximumExecutionFrequency` | No | How often Config re-evaluates all groups (default 24h) |

## Notes

- Deploy this **alongside** the `../event-driven/` template for both
  real-time revocation and periodic drift-catching — they use separate
  Lambda deployments (one per stack) so they're fully independent.
- Auto-remediation retries up to 3 times, 60 seconds apart, before giving
  up and leaving the resource flagged non-compliant for manual review.
