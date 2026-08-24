# Auto-Remediate Open SSH/RDP — Event-Driven (CloudFormation)

Revokes security group ingress rules that open **SSH (22)** or **RDP (3389)**
to `0.0.0.0/0` / `::/0`, within seconds of the rule being created.

## How it works

1. Someone (or something) calls `AuthorizeSecurityGroupIngress` and opens
   22 or 3389 to the internet.
2. That management API call is automatically delivered to EventBridge's
   default event bus by CloudTrail — **no dedicated trail needs to be
   created** for this to work; management events are available on the
   default bus in every account.
3. An EventBridge rule matches on `eventName: AuthorizeSecurityGroupIngress`
   and invokes a Lambda function.
4. The Lambda inspects exactly the rule(s) that were just added, and if
   they match the risky pattern, revokes them and publishes an SNS
   notification.

Because it only acts on the rule just created, it won't touch other,
legitimate ingress rules on the same security group.

Also included for defense-in-depth / hygiene: a customer-managed KMS key
encrypting the Lambda's log group and environment variables, a dead-letter
SQS queue for failed async invocations, and a reserved concurrency limit
(5) so this function can't consume the account's shared Lambda concurrency
pool. X-Ray tracing is on, log retention is 365 days, and there's an
optional code-signing-config hook for accounts that enforce Lambda code
signing.

> **Note:** this path only catches rules created *after* this stack is
> deployed. For drift / pre-existing open rules, deploy the sibling
> `../config-rule/` template as well — it re-evaluates all security groups
> on a schedule and remediates anything it finds.

## Deploying

CloudFormation can't zip and upload local files for you (that's a SAM/
`aws cloudformation package` feature), so package the Lambda first:

```bash
cd ../lambda
zip lambda.zip remediate_open_ssh_rdp.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/auto-remediate-open-ssh-rdp/lambda.zip
```

Then deploy the stack:

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name sg-auto-remediate-ssh-rdp \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      LambdaCodeS3Bucket=YOUR-BUCKET \
      NotificationEmail=you@example.com
```

For GovCloud, use the same commands against a GovCloud profile/region —
the template only uses `${AWS::Partition}` in ARNs, never a hardcoded
`arn:aws:...`.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `LambdaCodeS3Bucket` | Yes | Bucket holding the packaged `lambda.zip` |
| `LambdaCodeS3Key` | No | Key of the zip (default `auto-remediate-open-ssh-rdp/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS remediation topic |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce on this Lambda |

## Testing it

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp --port 22 --cidr 0.0.0.0/0
```

Within a few seconds the rule should be revoked automatically — check
CloudWatch Logs for the Lambda (`/aws/lambda/<stack-name>-remediate-open-ssh-rdp`)
and your inbox (if you set `NotificationEmail`) to confirm.
