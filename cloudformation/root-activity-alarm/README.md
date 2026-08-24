# root-activity-alarm (CloudFormation)

Fires an SNS notification within seconds of any **root user** activity —
console sign-in, API call, or AWS service event performed as root. No
Lambda involved: EventBridge invokes SNS directly via an input
transformer, so there's nothing to deploy code for and nothing that can
throttle or fail asynchronously.

## Why this in addition to the `deny-root-user` SCP

The [`scp-guardrails`](../../policies/scp-guardrails/) `deny-root-user`
policy *prevents* root from doing anything. This alarm is the detective
complement:

- Catches **attempts** to use root, which the SCP blocks but which are
  still worth knowing about (someone found/used the root credentials).
- Covers accounts where the SCP isn't deployed yet, or where root needs
  to remain usable for a specific break-glass procedure — you can allow
  root for that one thing and still get alerted every time it happens.
- Catches root **console sign-ins**, which the SCP doesn't prevent
  (SCPs govern authorization for actions, not authentication).

## Deploying

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name root-activity-alarm \
  --parameter-overrides NotificationEmail=you@example.com
```

Works the same in GovCloud — no partition is hardcoded.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `NotificationEmail` | No | Email to subscribe to the SNS topic |

## Notes

- This matches **every** root-attributed CloudTrail event, including some
  benign AWS-internal service events that occasionally show up as
  `userIdentity.type: Root` (most commonly around account creation).
  Expect a small amount of noise right after deploying a new account, and
  tune the `EventPattern` if a specific source turns out to be chatty.
- Consider subscribing a Lambda (or chat webhook via SNS→Lambda) instead
  of/alongside email for lower-latency paging during an active incident.
