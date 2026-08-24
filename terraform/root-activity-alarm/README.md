# root-activity-alarm (Terraform)

Fires an SNS notification within seconds of any **root user** activity —
console sign-in, API call, or AWS service event performed as root. No
Lambda involved: EventBridge invokes SNS directly via an input
transformer.

## Why this in addition to the `deny-root-user` SCP

The [`scp-guardrails`](../../policies/scp-guardrails/) `deny-root-user`
policy *prevents* root from doing anything. This alarm is the detective
complement:

- Catches **attempts** to use root, which the SCP blocks but which are
  still worth knowing about.
- Covers accounts where the SCP isn't deployed yet, or where root needs
  to remain usable for a specific break-glass procedure.
- Catches root **console sign-ins**, which the SCP doesn't prevent
  (SCPs govern authorization for actions, not authentication).

## Usage

```hcl
module "root_activity_alarm" {
  source = "github.com/DustyStudy/aws-cloud-security-toolbox//terraform/root-activity-alarm"

  notification_email = "you@example.com"
}
```

Works the same in GovCloud — no partition is hardcoded.

## Inputs

| Name | Description | Default |
|---|---|---|
| `name_prefix` | Prefix for all resource names | `root-activity-alarm` |
| `notification_email` | Email to subscribe to the SNS topic (optional) | `""` |

## Outputs

| Name | Description |
|---|---|
| `sns_topic_arn` | ARN of the SNS topic |
| `event_rule_arn` | ARN of the EventBridge rule |

## Notes

- Matches **every** root-attributed CloudTrail event, including some
  benign AWS-internal service events that occasionally show up as
  `userIdentity.type: Root` (most commonly around account creation).
  Expect a little noise right after a new account is created.
- Consider subscribing a Lambda (or chat webhook via SNS→Lambda) for
  lower-latency paging during an active incident.
