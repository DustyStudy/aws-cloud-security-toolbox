# wiz-finding-bridge (CloudFormation)

Receives Wiz webhook deliveries via an API Gateway HTTP API and bridges
them into this repo's existing patterns: an SNS notification matching
every other module here, and — optionally — an invocation of one of this
repo's own remediation Lambdas when a finding matches a configured
mapping.

## Read this before you deploy

This module is **schema-tolerant, not schema-assuming**. Wiz's outbound
webhook JSON shape isn't something verifiable from outside a live Wiz
tenant, and it's not something this repo asserts to know precisely. So
rather than hardcode field names that might be subtly wrong (and fail
silently), the Lambda:

- Reads which fields to treat as severity/title/resource from
  **dot-notation paths you configure** (`SeverityFieldPath`,
  `TitleFieldPath`, `ResourceFieldPath`), not hardcoded keys.
- **Always includes the raw payload** (truncated to 2000 characters) in
  the SNS message, so your first real finding tells you exactly what the
  actual field names are.
- **Fails open on an unresolved severity** — if `SeverityFieldPath`
  doesn't resolve to anything, the finding is still forwarded (marked
  "unresolved") rather than silently dropped below the threshold.

Plan on deploying this, sending one real test finding, reading the raw
payload in the SNS message, and then updating `SeverityFieldPath` /
`TitleFieldPath` / `ResourceFieldPath` to match. That's the intended
workflow, not a workaround.

The defaults above (`severity`, `title`, `primaryResource`) are set from
a real Wiz **Detection** payload (a Defend/threat-hunting event —
`mitreTactics`, `tdrSource`, `threatId`), not a guess. `severity` and
`title` are top-level strings in that shape; `primaryResource` is a
nested object whose internal fields weren't visible, so it's rendered as
JSON in the report rather than assumed into a sub-path. A Wiz **Issue**
(the CSPM misconfiguration findings — e.g. a security group open to the
internet) may use a different shape than a Detection; if your findings
come from Issues rather than Detections, treat these defaults as a
starting point to verify against your own first real delivery, not a
guarantee.

## How authentication works

As of this writing, Wiz's basic Webhook integration (Settings →
Integrations → **+ Add Integration** → **Webhook**) only lets you
configure a destination **URL** — no custom headers, no payload signing.
So instead of verifying a signature header, this module generates a long
random secret and expects it as the **last path segment of the webhook
URL itself** (`.../wiz-webhook/<secret>`) — the same "unguessable URL"
pattern most URL-only webhook integrations rely on. The secret lives in
Secrets Manager, never in the template or in plaintext parameters.

If your Wiz tenant's integration options have since added header-based
signing, that would be a stronger mechanism than this — check your Wiz
console before relying solely on the secret-in-URL approach for anything
particularly sensitive.

## Deploying

```bash
cd lambda
zip lambda.zip wiz_webhook_bridge.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/wiz-finding-bridge/lambda.zip
```

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name wiz-finding-bridge \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      LambdaCodeS3Bucket=YOUR-BUCKET \
      NotificationEmail=you@example.com
```

Then retrieve the generated secret and build the full webhook URL:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(aws cloudformation describe-stacks --stack-name wiz-finding-bridge \
      --query "Stacks[0].Outputs[?OutputKey=='WebhookSecretArn'].OutputValue" --output text)" \
  --query SecretString --output text
```

```bash
aws cloudformation describe-stacks --stack-name wiz-finding-bridge \
  --query "Stacks[0].Outputs[?OutputKey=='WebhookUrlBase'].OutputValue" --output text
```

Paste `<WebhookUrlBase>/wiz-webhook/<secret>` into Wiz's Webhook
integration URL field. Then create an **Automation Rule** (Policies →
Automation Rules → **+ Add Rule**) with a "When" condition like *Issue
Created* (or *Detection Created*, if you have Wiz Defend), an optional
severity "If" filter, and set the action to send to the webhook
integration you just created.

Works the same in GovCloud — HTTP APIs are fully supported there; only
edge-optimized endpoints and private VPC-link integrations have GovCloud
caveats, and this module uses neither.

## Wiring findings to existing remediation

Once you know your real Wiz payload's title/rule-name values (from the
raw-payload excerpt in an SNS message), you can route specific findings
straight into one of this repo's own remediation Lambdas — for example,
a Wiz finding about a security group open to the internet could invoke
[`auto-remediate-open-ssh-rdp`](../auto-remediate-open-ssh-rdp/)'s Lambda
directly:

```
RemediationLambdaMapping = {"Port 22/3389 open to 0.0.0.0/0": "arn:aws:lambda:us-east-1:123456789012:function:auto-remediate-open-ssh-rdp-...-remediate"}
RemediationLambdaArns    = arn:aws:lambda:us-east-1:123456789012:function:auto-remediate-open-ssh-rdp-...-remediate
```

`RemediationLambdaArns` must list every ARN used in the mapping — it's
what actually grants this Lambda's execution role permission to invoke
them. The mapped Lambda is invoked asynchronously with
`{"source": "wiz-finding-bridge", "finding": <normalized finding>}` as
its payload; it needs to be written to accept that shape, or you'll want
a small adapter in between rather than pointing straight at an existing
module's Lambda whose input contract wasn't designed for this.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `LambdaCodeS3Bucket` | Yes | Bucket holding the packaged `lambda.zip` |
| `LambdaCodeS3Key` | No | Key of the zip (default `wiz-finding-bridge/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS topic |
| `MinimumSeverity` | No | Lowest severity to notify on (default `HIGH`) |
| `SeverityFieldPath` | No | Dot-notation path to the severity field (default `severity`) |
| `TitleFieldPath` | No | Dot-notation path to the title field (default `title`) |
| `ResourceFieldPath` | No | Dot-notation path to the resource field (default `primaryResource`) |
| `RemediationLambdaMapping` | No | JSON string mapping title → remediation Lambda ARN (default `{}`) |
| `RemediationLambdaArns` | No | ARNs this bridge is allowed to invoke — must match the mapping |
| `ThrottleBurstLimit` / `ThrottleRateLimit` | No | API Gateway throttle settings (defaults `10` / `5`) |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce |

## Notes

- **No WAF in this template.** The endpoint is protected by the
  unguessable secret path segment plus stage-level throttling, not a
  network ACL. If you want IP-reputation filtering or rate-limiting
  beyond the built-in throttle settings, associate an
  `AWS::WAFv2::WebACL` with the stage separately — left out here to keep
  the module focused, not because it wouldn't help.
- The API Gateway access log intentionally excludes the request body
  (finding details can be sensitive) — only request metadata is logged.
  The Lambda's own CloudWatch logs will contain finding content, so
  their log group is KMS-encrypted like every other module here.
- A malformed or unauthenticated delivery always gets a fast HTTP
  response (`401` for a bad secret, `200` for a bad body) so Wiz doesn't
  pile up retries against a dead endpoint.
