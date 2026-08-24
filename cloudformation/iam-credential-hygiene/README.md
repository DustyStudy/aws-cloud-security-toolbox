# iam-credential-hygiene (CloudFormation)

Scans every IAM user's access keys on a schedule and **deactivates** (never
deletes) any key that's too old or unused for too long, notifying via SNS.
This is one of the most common CIS Benchmark / Wiz / Security Hub findings
in any account — this closes it automatically instead of relying on
someone reviewing a credential report.

Deactivating rather than deleting means a false positive is a quick
`aws iam update-access-key --status Active` away from being reversible,
rather than forcing the user to generate and redistribute a new key pair.

## How it works

1. A scheduled EventBridge rule (default: daily) invokes the Lambda.
2. The Lambda lists every IAM user and their access keys.
3. For each **active** key, it checks:
   - Age since creation (`MaxKeyAgeDays`, default 180) — deactivated
     regardless of use if exceeded.
   - Days since last use, or since creation if never used
     (`MaxUnusedDays`, default 90).
4. Any key crossing either threshold is set to `Inactive`, and a summary
   of everything deactivated (user, key ID, reason) is published to SNS.

Users tagged with `ExemptTagKey` (optionally matching `ExemptTagValue`)
are skipped entirely — use this for break-glass or service accounts that
intentionally hold long-lived keys.

## Deploying

Package the Lambda first (no third-party dependencies, just `boto3`,
which is in the standard runtime):

```bash
cd lambda
zip lambda.zip deactivate_stale_iam_keys.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/iam-credential-hygiene/lambda.zip
```

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name iam-credential-hygiene \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      LambdaCodeS3Bucket=YOUR-BUCKET \
      NotificationEmail=you@example.com \
      MaxKeyAgeDays=180 \
      MaxUnusedDays=90
```

Works the same in GovCloud — no partition is hardcoded.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `LambdaCodeS3Bucket` | Yes | Bucket holding the packaged `lambda.zip` |
| `LambdaCodeS3Key` | No | Key of the zip (default `iam-credential-hygiene/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS topic |
| `MaxKeyAgeDays` | No | Deactivate active keys older than this (default 180) |
| `MaxUnusedDays` | No | Deactivate active keys unused this long (default 90) |
| `ScheduleExpression` | No | EventBridge schedule (default `rate(1 day)`) |
| `ExemptTagKey` / `ExemptTagValue` | No | Skip users carrying this tag |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce |

## Notes

- Only **access keys** are handled here, not IAM users or passwords — a
  separate exercise if you also want to prune unused IAM users or enforce
  console password rotation.
- Consider starting with generous thresholds and a wide `NotificationEmail`
  audience to see what would be caught before tightening — a surprising
  number of "temporary" keys tend to be load-bearing.
