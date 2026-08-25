# sagemaker-notebook-exposure / config-rule (CloudFormation)

Continuous-compliance path: an AWS Config managed rule
(`SAGEMAKER_NOTEBOOK_NO_DIRECT_INTERNET_ACCESS`) evaluates every SageMaker
notebook instance on a schedule, flagging any with direct internet access
enabled. A built-in SSM Automation document invokes the same remediation
Lambda used by `../event-driven/` to stop and reconfigure it — catching
notebooks that existed before this stack was deployed, or that drifted
outside the event-driven path's coverage.

## Important limitation

There is **no AWS Config managed rule for notebook root access** as of
this writing — only direct internet access has one. That means:

- This path catches **pre-existing or drifted direct-internet-access**
  notebooks.
- It does **not** catch pre-existing root-access-enabled notebooks that
  were never touched by a `CreateNotebookInstance`/`UpdateNotebookInstance`
  event since `../event-driven/` was deployed.

Deploy both templates for the best coverage, and consider a one-time
manual audit (`aws sagemaker list-notebook-instances` +
`describe-notebook-instance` per instance) to catch any pre-existing
root-access notebooks this doesn't reach.

## Prerequisites

**AWS Config must already be enabled** in the account/region.

## Deploying

```bash
cd ../lambda
zip lambda.zip remediate_sagemaker_notebook_exposure.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/sagemaker-notebook-exposure/lambda.zip
```

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name sagemaker-notebook-exposure-config-rule \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      LambdaCodeS3Bucket=YOUR-BUCKET \
      NotificationEmail=you@example.com \
      MaximumExecutionFrequency=TwentyFour_Hours
```

Works the same in GovCloud.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `LambdaCodeS3Bucket` | Yes | Bucket holding the packaged `lambda.zip` |
| `LambdaCodeS3Key` | No | Key of the zip (default `sagemaker-notebook-exposure/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS topic |
| `AutoRestart` | No | Restart the notebook after remediation (default `false`) |
| `MaximumExecutionFrequency` | No | How often Config re-evaluates all notebooks (default 24h) |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce |

## Notes

- This stack deploys its **own** copy of the remediation Lambda (separate
  from `../event-driven/`'s) — the two templates are fully independent,
  matching the pattern used elsewhere in this repo.
  (`auto-remediate-open-ssh-rdp` does the same.)
- It also includes its own `NotebookStateChangeRule` so notebooks it
  flags and stops still get their settings fixed once actually stopped —
  the SSM Automation invocation only performs the "flag and stop" half.
- Auto-remediation retries up to 3 times, 60 seconds apart, before
  leaving the resource flagged non-compliant for manual review.
