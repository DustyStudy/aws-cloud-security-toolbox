# bedrock-logging-enforcement (CloudFormation)

Checks the account's Bedrock **model invocation logging** configuration on
a schedule and re-enables it if it's missing or was disabled, notifying
via SNS. This is the only audit trail of what prompts and completions
actually passed through your models — without it, an incident involving
a leaked prompt or a jailbroken agent is nearly unreconstructable after
the fact. Turning it off is a single API call, and easy to not notice.

## How it works

1. A scheduled EventBridge rule (default: daily) invokes the Lambda.
2. The Lambda calls `bedrock:GetModelInvocationLoggingConfiguration` and
   compares it against the desired configuration (S3 bucket + CloudWatch
   Logs group, both created by this stack).
3. If logging is disabled, or pointed somewhere unexpected, the Lambda
   calls `bedrock:PutModelInvocationLoggingConfiguration` to restore it,
   and publishes a summary to SNS.

Both an S3 bucket and a CloudWatch Logs group are configured as
destinations — S3 for cheap long-term retention, CloudWatch for quick
querying via Logs Insights or wiring into metric filters/alarms.

## Deploying

```bash
cd lambda
zip lambda.zip enforce_bedrock_logging.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/bedrock-logging-enforcement/lambda.zip
```

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name bedrock-logging-enforcement \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      LambdaCodeS3Bucket=YOUR-BUCKET \
      NotificationEmail=you@example.com
```

Works the same in GovCloud — check that Bedrock is available in your
target GovCloud region first (model availability varies by region).

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `LambdaCodeS3Bucket` | Yes | Bucket holding the packaged `lambda.zip` |
| `LambdaCodeS3Key` | No | Key of the zip (default `bedrock-logging-enforcement/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS topic |
| `ScheduleExpression` | No | EventBridge schedule (default `rate(1 day)`) |
| `LogTextData` | No | Log text prompts/completions (default `true`) |
| `LogImageData` | No | Log image inputs/outputs (default `false` — can be large) |
| `LogEmbeddingData` | No | Log embedding inputs (default `false`) |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce |

## Notes

- The S3 destination bucket uses SSE-S3, not SSE-KMS — this is a
  documented AWS limitation of Bedrock's S3 log-delivery mechanism, not
  an oversight.
- Only account-level (not per-model or per-application-inference-profile)
  logging is covered here. If you use application inference profiles with
  their own logging needs, extend the Lambda accordingly.
- Pair this with [`ai-ml-guardrails`](../ai-ml-guardrails/)'s
  `deny-disable-bedrock-logging-and-guardrails` SCP for a
  prevent-and-detect combination — the SCP stops the config from being
  deleted outright, this catches drift and re-establishes it if it
  happens anyway (e.g. before the SCP was deployed, or in an account
  outside its scope).
