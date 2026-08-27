# stale-account-detector (CloudFormation)

Scans every **ACTIVE** account in the AWS Organization for CloudTrail
activity in the last N days, using an organization-wide **CloudTrail
Lake** event data store queried with plain SQL — no Athena/Glue setup,
no per-account role assumption. Emails a report via SNS **only when it
actually finds stale accounts** — a scan that finds nothing sends no
email at all.

## Why CloudTrail Lake instead of parsing raw CloudTrail logs

CloudTrail Lake is purpose-built for exactly this kind of ad-hoc,
cross-account SQL query. The alternative — Athena over the raw S3
CloudTrail logs from an [`organization-trail`](../security-baseline-new-accounts/organization-trail/)-style
trail — works too, but means you maintain Glue table partitioning
yourself. This tool creates and queries its own event data store
instead (or reuses an existing one, see below).

## How "stale" is determined

1. List every `ACTIVE` account in the Organization.
2. Run one CloudTrail Lake query covering the last
   `ActivityLookbackDays` days, grouped by `recipientAccountId`,
   returning each account's most recent event of any kind and its most
   recent `ConsoleLogin` event specifically.
3. Any `ACTIVE` account with **no row** in those results had zero
   recorded CloudTrail activity (management events) in the lookback
   window — that's what gets reported as stale.
4. Accounts that show up with only non-interactive API activity (no
   `ConsoleLogin`) are **not** treated as stale, but are called out
   separately in the report for context — could be a legitimate
   automation-only account, or a human-owned account nobody's manually
   reviewed in a while.

This only sees what's actually in the event data store: if the store is
newer than the lookback period, "no activity in N days" means "no
activity since the store started ingesting," not "no activity ever."

## Deploying

Deploy in the Organizations **management account**, or a registered
delegated administrator for CloudTrail — only there can you list every
account in the org and query an organization-scoped event data store.

```bash
cd lambda
zip lambda.zip detect_stale_accounts.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/stale-account-detector/lambda.zip
```

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name stale-account-detector \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      LambdaCodeS3Bucket=YOUR-BUCKET \
      NotificationEmail=you@example.com \
      ActivityLookbackDays=90 \
      ScheduleExpression="rate(7 days)"
```

To reuse an existing organization-wide event data store instead of
creating a new one (recommended if you already have one — CloudTrail
Lake bills by ingestion volume, and a duplicate store just doubles that
cost for no benefit):

```bash
--parameter-overrides \
    CreateEventDataStore=false \
    ExistingEventDataStoreArn=arn:aws:cloudtrail:us-east-1:123456789012:eventdatastore/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
    ...
```

Works the same in GovCloud.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `LambdaCodeS3Bucket` | Yes | Bucket holding the packaged `lambda.zip` |
| `LambdaCodeS3Key` | No | Key of the zip (default `stale-account-detector/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS topic |
| `ScheduleExpression` | No | EventBridge schedule (default `rate(7 days)`) |
| `ActivityLookbackDays` | No | Days of no activity before an account is flagged stale (default `90`) |
| `ExcludedAccountIds` | No | Account IDs to always skip |
| `ExemptTagKey` / `ExemptTagValue` | No | Skip accounts carrying this Organizations tag |
| `CreateEventDataStore` | No | Create a new org-wide event data store (default `true`) |
| `ExistingEventDataStoreArn` | Conditional | Required if `CreateEventDataStore=false` |
| `EventDataStoreRetentionDays` | No | Retention for a newly-created store (default `92`) |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce |

## Notes

- The event data store this template creates is scoped to **management
  events only** (no data events) — data events are high-volume and
  costlier to ingest, and account staleness only needs to know whether
  *anyone did anything* in an account, which management events already
  capture, including `ConsoleLogin`.
- `TerminationProtectionEnabled: true` on the created event data store —
  deleting it also deletes its ingested history, so this is deliberately
  not a one-command teardown. Disable termination protection explicitly
  first if you really mean to delete it.
- If your organization already has an [`organization-trail`](../security-baseline-new-accounts/organization-trail/)
  deployed, that's a **separate** resource from a CloudTrail Lake event
  data store (different pricing model, different query mechanism) — this
  tool doesn't read from that trail's S3 bucket directly.
- Consider starting with a longer `ActivityLookbackDays` (e.g. 180) for
  the first run or two, since a newly-created event data store has no
  history yet and every account will look "stale" until it's ingested
  enough real activity to tell the difference.
