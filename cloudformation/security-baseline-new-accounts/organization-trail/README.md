# security-baseline-new-accounts / organization-trail (CloudFormation)

Creates a single **AWS Organization CloudTrail trail** that automatically
covers every account in the Organization — including accounts created
later. This is the architecturally correct way to get CloudTrail
everywhere: one trail, not one per account.

## Prerequisites

CloudTrail must have trusted access enabled for your Organization (usually
already the case if you've used Organizations for anything else, but if
not: Organizations console → Services → CloudTrail → Enable trusted
access).

Deploy this stack from the **Organizations management account** or a
registered delegated administrator account for CloudTrail.

## Deploying

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name organization-cloudtrail \
  --parameter-overrides \
      TrailName=organization-trail \
      OrganizationId=o-abc123xyz0
```

`OrganizationId` is optional — omit it if member accounts won't need to
decrypt the logs directly (e.g. all log analysis happens centrally from
the management/log-archive account).

Works the same in GovCloud — no partition is hardcoded.

## What this creates

- A multi-region, organization-wide CloudTrail trail with log file
  validation enabled.
- An S3 bucket (versioned, public access fully blocked, server access
  logging to a companion access-log bucket, lifecycle rules transitioning
  to IA at 90 days and Glacier at 365, expiring at `LogRetentionDays` —
  ~7 years by default) plus EventBridge notifications on the bucket.
- A customer-managed KMS key encrypting the trail logs.
- An SNS topic CloudTrail publishes to whenever it delivers a new log
  file — subscribe your own tooling to it if you want to react to log
  delivery in near-real-time rather than polling S3.
- A CloudWatch Logs group (with its own IAM role for CloudTrail to
  assume) receiving trail events, so you can build metric filters and
  alarms directly from CloudTrail activity.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `TrailName` | No | Name for the trail (default `organization-trail`) |
| `OrganizationId` | No | Grants org member accounts `kms:Decrypt` on the trail key if set |
| `LogRetentionDays` | No | Days before trail logs expire (default `2555`, ~7 years) |

## Notes

- Only **one** organization trail is needed per Organization, period — do
  not deploy this stack more than once, and do not also deploy a
  per-account trail in member accounts (that just duplicates events).
- This deploys separately from `../member-baseline/` on purpose:
  StackSets deploy the same template to many accounts, but an org trail
  is a single resource — folding it into the per-account StackSet would
  mean attempting to create a duplicate organization trail in every
  account, which CloudTrail rejects.
- Cross-region replication of the trail bucket is deliberately **not**
  included — it doubles storage cost and adds a second region. Add an
  `AWS::S3::Bucket` `ReplicationConfiguration` if your compliance regime
  requires geographic redundancy for trail logs (there's a `checkov:skip`
  marking exactly where in `template.yaml`).
