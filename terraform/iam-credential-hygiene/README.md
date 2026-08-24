# iam-credential-hygiene (Terraform)

Scans every IAM user's access keys on a schedule and **deactivates** (never
deletes) any key that's too old or unused for too long, notifying via SNS.
This is one of the most common CIS Benchmark / Wiz / Security Hub findings
in any account — this closes it automatically instead of relying on
someone reviewing a credential report.

Deactivating rather than deleting means a false positive is a quick
`aws iam update-access-key --status Active` away from being reversible.

## How it works

1. A scheduled EventBridge rule (default: daily, via `schedule_expression`)
   invokes the Lambda.
2. The Lambda lists every IAM user and their access keys.
3. For each **active** key, it checks age since creation
   (`max_key_age_days`, default 180) and days since last use, or since
   creation if never used (`max_unused_days`, default 90).
4. Any key crossing either threshold is set to `Inactive`, and a summary
   is published to SNS.

Users tagged with `exempt_tag_key` (optionally matching
`exempt_tag_value`) are skipped entirely.

## Usage

```hcl
module "iam_credential_hygiene" {
  source = "github.com/DustyStudy/aws-cloud-security-toolbox//terraform/iam-credential-hygiene"

  notification_email = "you@example.com"
  max_key_age_days    = 180
  max_unused_days     = 90
}
```

Requires the `hashicorp/archive` provider in addition to `hashicorp/aws`.
Works the same in GovCloud.

## Inputs

| Name | Description | Default |
|---|---|---|
| `name_prefix` | Prefix for all resource names | `iam-credential-hygiene` |
| `notification_email` | Email to subscribe to the SNS topic (optional) | `""` |
| `max_key_age_days` | Deactivate active keys older than this | `180` |
| `max_unused_days` | Deactivate active keys unused this long | `90` |
| `schedule_expression` | EventBridge schedule | `rate(1 day)` |
| `exempt_tag_key` / `exempt_tag_value` | Skip users carrying this tag | `""` / `""` |
| `code_signing_config_arn` | ARN of an existing code-signing config (optional) | `null` |

## Outputs

| Name | Description |
|---|---|
| `lambda_function_arn` | ARN of the hygiene Lambda |
| `sns_topic_arn` | ARN of the SNS notification topic |

## Notes

- Only **access keys** are handled here, not IAM users or console
  passwords.
- Consider starting with generous thresholds and a wide notification
  audience to see what would be caught before tightening.
