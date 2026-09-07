# identity-center-access-auditor (CloudFormation)

Audits AWS IAM Identity Center (successor to AWS SSO) on a schedule for
three common access-governance risks: over-privileged permission sets,
account assignments made directly to a user instead of a group, and
unused permission sets. **Detective only** — this never modifies a
permission set or assignment, since automatically revoking access could
break someone's job in the middle of their day. A human should review
and right-size deliberately.

## The risk this targets

Identity Center is where most organizations centralize *who can do what,
where* across an entire AWS Organization — which makes its own
misconfigurations high-leverage. A single permission set with
`AdministratorAccess` provisioned to every account is a much bigger
blast radius than the same mistake in one account's IAM. And because
Identity Center makes it just as easy to assign access to an individual
user as to a group, it's easy for "just this once" direct assignments to
accumulate quietly until nobody can say why a given person has access to
a given account without checking case by case.

## How it works

A scheduled EventBridge rule (default: daily) invokes the Lambda, which
walks every Identity Center instance in the account (normally exactly
one — the Organization instance) and runs three checks:

**1. Over-privileged permission sets** — for every permission set, the
Lambda checks:
   - Whether the `AdministratorAccess` AWS-managed policy is attached
   - Whether its inline policy contains a full wildcard action
     (`"Action": "*"`) or a service-wide wildcard (e.g. `iam:*`) on one
     of `SensitiveWildcardServices`, combined with `Resource: "*"`

   Any match is reported together with how many accounts the permission
   set is provisioned to and whether it's also assigned directly to a
   user (see check 2) — `AdministratorAccess` assigned org-wide is a very
   different risk than the same policy scoped to one break-glass group in
   one account.

**2. Direct-to-user account assignments** — independent of privilege
level, any account assignment whose principal is a user rather than a
group is flagged. Assignments should generally flow through groups so
access can be reasoned about and rotated as people change teams, not
tracked person-by-person across every account. Set
`FlagDirectUserAssignments=false` to disable this check.

**3. Unused permission sets** — permission sets created but currently
provisioned to zero accounts. Not a security finding by itself, just
hygiene — reported as an informational addendum whenever the audit
already has real findings to report, never as the sole reason to notify.

Findings are combined into a single SNS summary. A clean scan (no
over-privileged permission sets and no direct-to-user assignments) sends
nothing, even if unused permission sets exist.

## Deploying

```bash
cd lambda
zip lambda.zip audit_identity_center_access.py
aws s3 cp lambda.zip s3://YOUR-BUCKET/identity-center-access-auditor/lambda.zip
```

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name identity-center-access-auditor \
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
| `LambdaCodeS3Key` | No | Key of the zip (default `identity-center-access-auditor/lambda.zip`) |
| `NotificationEmail` | No | Email to subscribe to the SNS topic |
| `ScheduleExpression` | No | EventBridge schedule (default `rate(1 day)`) |
| `SensitiveWildcardServices` | No | Services where `<service>:*` + `Resource: "*"` is flagged |
| `FlagDirectUserAssignments` | No | Flag user (vs group) account assignments (default `true`) |
| `ReportUnusedPermissionSets` | No | Include the unused-permission-set addendum when there's other findings (default `true`) |
| `CodeSigningConfigArn` | No | ARN of an existing AWS Signer code-signing config to enforce |

## Before you deploy

- **Deploy from the account where Identity Center is enabled** — the
  Organization's management account, or a delegated administrator
  account if you've registered one (Identity Center → Settings →
  Delegated administrator). Identity Center is Organization-wide, not
  per-account, so this only needs to run once.
- **Deploy in Identity Center's "home Region"** — check Identity Center
  → Settings → Details in the console for which Region your instance
  actually lives in. The `sso-admin` API calls in this Lambda only see
  instances in the Region the Lambda itself runs in.

## Notes

- Only **AWS-managed** policy content is evaluated for check 1.
  Customer-managed policies attached to a permission set are counted and
  named in the report, but their content isn't fetched — the underlying
  IAM policy for a customer-managed reference lives per-account, not
  centrally, so evaluating it would mean assuming a role in every target
  account. Out of scope for a single-account auditor; if your org relies
  heavily on customer-managed policies in permission sets, extend the
  Lambda to assume a read-only role into each target account and fetch
  the policy document there.
- Friendly account names in the report depend on `organizations:ListAccounts`,
  which is included in the Lambda's permissions. If your delegated
  administrator account doesn't have Organizations read access for some
  reason, the report falls back to raw account IDs — everything else
  still works.
- This is purely additive to [`scp-guardrails`](../scp-guardrails/): SCPs
  constrain what an already-granted permission set can actually do
  account-wide; this audits how permission sets and assignments
  themselves are structured, which SCPs can't see into.
- False positives are expected and fine here — a break-glass permission
  set with `AdministratorAccess` scoped to a single group in a single
  account will still get flagged. The point is visibility into what
  exists, not a hard gate.
