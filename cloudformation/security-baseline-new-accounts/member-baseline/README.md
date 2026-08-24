# security-baseline-new-accounts / member-baseline (CloudFormation)

A CloudFormation **StackSet** (service-managed, auto-deployment enabled)
that enables GuardDuty, Security Hub, and AWS Config in every account
within a target Organizational Unit — including accounts created *after*
this stack is deployed. This is the fix for "the new account got missed"
in multi-account governance.

## Prerequisites

1. **Trusted access for CloudFormation StackSets** must be enabled for
   your Organization:
   ```bash
   aws organizations enable-aws-service-access \
     --service-principal member.org.stacksets.cloudformation.amazonaws.com
   ```
   (or Organizations console → Services → CloudFormation StackSets →
   Enable trusted access.)
2. Deploy this stack from the **Organizations management account**, or
   from an account [registered as a delegated administrator][delegated-admin]
   for CloudFormation StackSets (set `CallAs=DELEGATED_ADMIN` in that case).

[delegated-admin]: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_integrate_services.html

## Deploying

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name security-baseline-new-accounts \
  --parameter-overrides \
      TargetOrganizationalUnitIds=ou-abcd-11111111 \
      Regions=us-east-1
```

For GovCloud:

```bash
--parameter-overrides \
    TargetOrganizationalUnitIds=ou-abcd-11111111 \
    Regions=us-gov-west-1,us-gov-east-1
```

## What gets deployed in each member account

- **GuardDuty** — a detector, 15-minute finding publish frequency.
- **Security Hub** — enabled with the default standards.
- **AWS Config** — a configuration recorder + delivery channel, backed by
  a per-account, per-region S3 bucket (`aws-config-<account-id>-<region>`)
  with public access fully blocked and SSE-S3 encryption.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `TargetOrganizationalUnitIds` | Yes | OU ID(s) to deploy the baseline to |
| `Regions` | No | Region(s) to enable the baseline in per account (default `us-east-1`) |
| `CallAs` | No | `SELF` (management account) or `DELEGATED_ADMIN` |

## Notes

- **`IncludeGlobalResourceTypes` is deliberately `false`** in the embedded
  per-account template, because the same template is applied in every
  region you list — if it were `true` everywhere, IAM and other global
  resources would be recorded multiple times per account. If you want
  global resource tracking, fork the embedded `TemplateBody` and set it
  `true` in exactly one designated region's stack instance (this requires
  per-region template variants, which is a customization beyond this
  starter).
- This does **not** set up CloudTrail — see the sibling
  `../organization-trail/` template. An AWS Organization trail is a
  single resource that covers every account automatically; it doesn't fit
  the per-account StackSet pattern and shouldn't be duplicated per account.
- `RetainStacksOnAccountRemoval: false` means the baseline stack (and its
  Config S3 bucket) is deleted if an account leaves the target OU. Change
  this if you'd rather retain the Config history for departed accounts.
- Removing an account from the target OU, or deleting this stack, does
  **not** retroactively disable GuardDuty/Security Hub if
  `RetainStacksOnAccountRemoval` is left `false` and the account simply
  moves elsewhere in the org — StackSets only manages what's currently in
  scope.
