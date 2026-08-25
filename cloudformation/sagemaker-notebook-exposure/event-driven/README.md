# sagemaker-notebook-exposure / event-driven (CloudFormation)

Detects SageMaker notebook instances created or updated with **direct
internet access** or **root access** enabled — the single most common
SageMaker misconfiguration, effectively an unmanaged EC2 instance with
AWS credentials attached, reachable from the internet — and remediates
them automatically.

## Why this is two EventBridge rules, not one

SageMaker only allows changing `DirectInternetAccess` or `RootAccess`
while a notebook instance is **stopped**. A single Lambda invocation
can't just "fix it" — stopping a running instance takes a couple of
minutes, longer than makes sense to block inside one invocation. So this
is a two-phase flow, both handled by the same Lambda:

1. **`NotebookCreateOrUpdateRule`** — matches
   `CreateNotebookInstance`/`UpdateNotebookInstance` CloudTrail events. If
   the notebook is non-compliant, the Lambda tags it
   `sagemaker-remediation-pending=true` and stops it if running.
2. **`NotebookStateChangeRule`** — matches SageMaker's own **native**
   "Notebook Instance State Change" EventBridge event. When a notebook
   reaches `Stopped` and carries the pending tag, the Lambda disables
   `DirectInternetAccess`/`RootAccess`, clears the tag, and (only if
   `AutoRestart=true`) starts it back up.

By default the notebook is left **stopped** after remediation, so an
admin can review before bringing it back online — set `AutoRestart=true`
if you'd rather it come back up automatically once compliant.

## Deploying

```bash
cd ../lambda
zip lambda.zip remediate_sagemaker_notebook_exposure.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/sagemaker-notebook-exposure/lambda.zip
```

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name sagemaker-notebook-exposure-event-driven \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      LambdaCodeS3Bucket=YOUR-BUCKET \
      NotificationEmail=you@example.com
```

Works the same in GovCloud — check SageMaker's availability in your
target GovCloud region first.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `LambdaCodeS3Bucket` | Yes | Bucket holding the packaged `lambda.zip` |
| `LambdaCodeS3Key` | No | Key of the zip (default `sagemaker-notebook-exposure/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS topic |
| `AutoRestart` | No | Restart the notebook after remediation (default `false`) |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce |

## Testing it

```bash
aws sagemaker create-notebook-instance \
  --notebook-instance-name test-exposure-check \
  --instance-type ml.t3.medium \
  --role-arn arn:aws:iam::ACCOUNT_ID:role/YourSageMakerExecutionRole \
  --direct-internet-access Enabled
```

Within a few minutes you should see the notebook get tagged, stopped, and
then reconfigured with direct internet access disabled — check
CloudWatch Logs for the Lambda and your inbox for the SNS notifications.

## Notes

- Deploy alongside `../config-rule/` to also catch pre-existing notebooks
  and drift — that path only covers direct internet access (there's no
  AWS Config managed rule for notebook root access yet), so this
  event-driven path is still the only coverage for newly-set root access.
