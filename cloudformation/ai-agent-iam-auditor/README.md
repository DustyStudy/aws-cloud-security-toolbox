# ai-agent-iam-auditor (CloudFormation)

Scans every IAM role's trust policy for AI/agent service principals
(Bedrock, SageMaker, Amazon Q) on a schedule, and for any matching role,
flags overly-broad attached/inline permissions. **Detective only** — this
never modifies anything, since automatically stripping an agent's
permissions could break its intended function. A human should review and
right-size these roles deliberately.

## The risk this targets

Agentic AI workflows often get built by handing the agent's execution
role broad permissions "to get it working," since the agent may need to
call many different APIs depending on what task it's given. That's a much
larger blast radius than a human operator with the same role, because the
agent can be steered — via prompt injection, a bad task description, or
just an overzealous framework default — into calling any API the role
permits, at machine speed, with no human in the loop to notice something's
wrong before it's done.

## How it works

1. A scheduled EventBridge rule (default: daily) invokes the Lambda.
2. The Lambda lists every IAM role and checks each one's trust policy for
   a `Principal.Service` matching `AIServicePrincipals` (Bedrock,
   SageMaker, Amazon Q, and Q Business by default).
3. For every matching role, it inspects all attached AWS-managed policies
   and inline policies for:
   - A full wildcard action (`"Action": "*"`)
   - A service-wide wildcard (e.g. `iam:*`, `ec2:*`) on one of
     `SensitiveWildcardServices`, combined with `Resource: "*"`
   - The `AdministratorAccess` managed policy attached
4. Any role with findings is included in a single SNS summary listing the
   role, which service(s) trust it, and what was flagged.

## Deploying

```bash
cd lambda
zip lambda.zip audit_ai_agent_iam_roles.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/ai-agent-iam-auditor/lambda.zip
```

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name ai-agent-iam-auditor \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      LambdaCodeS3Bucket=YOUR-BUCKET \
      NotificationEmail=you@example.com
```

Works the same in GovCloud.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `LambdaCodeS3Bucket` | Yes | Bucket holding the packaged `lambda.zip` |
| `LambdaCodeS3Key` | No | Key of the zip (default `ai-agent-iam-auditor/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS topic |
| `ScheduleExpression` | No | EventBridge schedule (default `rate(1 day)`) |
| `AIServicePrincipals` | No | Trust-policy service principals treated as "AI/agent" |
| `SensitiveWildcardServices` | No | Services where `<service>:*` + `Resource: "*"` is flagged |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce |

## Notes

- Only **AWS-managed** policies are evaluated by default (the IAM
  permissions granted to the Lambda are scoped to
  `arn:...:iam::aws:policy/*`). If your org attaches customer-managed
  policies to AI/agent roles too, broaden the `iam:GetPolicy`/
  `iam:GetPolicyVersion` resource scope in `template.yaml` to include
  `arn:...:iam::<account-id>:policy/*`.
- This is purely additive to [`ai-ml-guardrails`](../ai-ml-guardrails/):
  the SCPs there govern what AI *services* can do account-wide; this
  audits what specific *agent roles* can do, which SCPs generally can't
  see into (SCPs constrain API calls, not the contents of an IAM policy
  document being created).
- False positives are expected and fine here — a role trusted by Bedrock
  that also needs `s3:*` for a legitimate data-processing pipeline will
  get flagged. The point is visibility, not a hard gate.
