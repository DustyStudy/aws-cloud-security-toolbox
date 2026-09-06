# scp-guardrails (CloudFormation)

Deploys the SCP library in [`policies/scp-guardrails/`](../../policies/scp-guardrails/)
and attaches them to the Organizations targets (OUs, accounts, or the
root) you specify — `deny-root-user`, `deny-disable-security-services`,
`require-imdsv2`, `deny-leave-organization`,
`deny-disable-s3-public-access-block`, and an optional `restrict-regions`.

Full policy descriptions, parameters, deployment commands, and GovCloud
notes live in [`policies/scp-guardrails/README.md`](../../policies/scp-guardrails/README.md#using-cloudformation) —
this directory just holds the template (`template.yaml`).

Quick start:

```bash
cd cloudformation/scp-guardrails
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name scp-guardrails \
  --parameter-overrides \
      TargetIds=ou-abcd-11111111,123456789012 \
      EnableRestrictRegions=true \
      AllowedRegions=us-gov-west-1,us-gov-east-1
```
