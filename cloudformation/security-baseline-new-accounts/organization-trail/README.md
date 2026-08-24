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
- An S3 bucket (versioned, public access fully blocked, lifecycle rules
  transitioning to IA at 90 days and Glacier at 365, expiring at ~7 years
  by default — adjust `ExpirationInDays` to your retention requirement).
- A customer-managed KMS key encrypting the trail logs.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `TrailName` | No | Name for the trail (default `organization-trail`) |
| `OrganizationId` | No | Grants org member accounts `kms:Decrypt` on the trail key if set |

## Notes

- Only **one** organization trail is needed per Organization, period — do
  not deploy this stack more than once, and do not also deploy a
  per-account trail in member accounts (that just duplicates events).
- This deploys separately from `../member-baseline/` on purpose:
  StackSets deploy the same template to many accounts, but an org trail
  is a single resource — folding it into the per-account StackSet would
  mean attempting to create a duplicate organization trail in every
  account, which CloudTrail rejects.
