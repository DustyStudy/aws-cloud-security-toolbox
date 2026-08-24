# security-baseline-new-accounts / organization-trail (Terraform)

Creates a single **AWS Organization CloudTrail trail** that automatically
covers every account in the Organization — including accounts created
later. This is the architecturally correct way to get CloudTrail
everywhere: one trail, not one per account.

## Prerequisites

CloudTrail must have trusted access enabled for your Organization
(usually already the case if you've used Organizations for anything
else; otherwise: Organizations console → Services → CloudTrail → Enable
trusted access).

Apply this module from the **Organizations management account** or a
registered delegated administrator account for CloudTrail.

## Usage

```hcl
module "organization_trail" {
  source = "github.com/DustyStudy/aws-cloud-security-toolbox//terraform/security-baseline-new-accounts/organization-trail"

  trail_name      = "organization-trail"
  organization_id = "o-abc123xyz0"
}
```

`organization_id` is optional — omit it if member accounts won't need to
decrypt the logs directly (e.g. all log analysis happens centrally from
the management/log-archive account).

Works the same in GovCloud.

## What this creates

- A multi-region, organization-wide CloudTrail trail with log file
  validation enabled.
- An S3 bucket (versioned, public access fully blocked, lifecycle rules
  transitioning to IA at 90 days and Glacier at 365, expiring at
  `log_retention_days` — ~7 years by default).
- A customer-managed KMS key encrypting the trail logs.

## Inputs

| Name | Description | Default |
|---|---|---|
| `trail_name` | Name for the trail (also derives the bucket name) | `organization-trail` |
| `organization_id` | Grants org member accounts `kms:Decrypt` on the trail key if set | `""` |
| `log_retention_days` | Days before trail logs expire | `2555` (~7 years) |

## Outputs

| Name | Description |
|---|---|
| `trail_arn` | ARN of the Organization trail |
| `trail_bucket_name` | Name of the S3 bucket holding logs for every account |

## Notes

- Only **one** organization trail is needed per Organization — do not
  apply this module more than once, and do not also deploy a per-account
  trail in member accounts (that just duplicates events).
- This is applied separately from `../member-baseline/` on purpose: a
  StackSet deploys the same template to many accounts, but an org trail
  is a single resource — folding it into the per-account baseline would
  mean attempting to create a duplicate organization trail in every
  account, which CloudTrail rejects.
