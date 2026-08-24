# aws-cloud-security-toolbox

Practical CloudFormation and Terraform for cloud security engineers —
guardrails, auto-remediation, and detection templates for day-to-day AWS
security work. Every template is written to run in both **AWS commercial
and AWS GovCloud** (no hardcoded `arn:aws:...`, `${AWS::Partition}` / the
`aws_partition` data source is used throughout).

This is a general-purpose companion to [`fedramp-cfn-library`](https://github.com/DustyStudy/fedramp-cfn-library)
and [`fedramp-terraform-library`](https://github.com/DustyStudy/fedramp-terraform-library),
which focus specifically on FedRAMP Moderate/High/20x control mappings.
Templates here aren't tied to a specific compliance framework — they're
just useful guardrails.

## Structure

Each tool/template lives in its own directory, mirrored under both
`cloudformation/` and `terraform/` where practical:

```
aws-cloud-security-toolbox/
├── cloudformation/
│   ├── auto-remediate-open-ssh-rdp/
│   │   ├── event-driven/       # EventBridge + CloudTrail, near real-time
│   │   ├── config-rule/        # AWS Config + SSM Automation, catches drift
│   │   └── lambda/             # shared Lambda source (CFN's own copy)
│   ├── scp-guardrails/         # deploys the SCPs below, attached to Organizations targets
│   ├── root-activity-alarm/    # EventBridge -> SNS on any root activity
│   ├── iam-credential-hygiene/ # scheduled deactivation of stale IAM keys
│   ├── ec2-isolation-runbook/  # on-demand SSM runbook to quarantine a compromised instance
│   └── security-baseline-new-accounts/
│       ├── member-baseline/    # StackSet: GuardDuty+SecurityHub+Config for every account in an OU
│       └── organization-trail/ # one-time org-wide CloudTrail trail
├── terraform/
│   ├── auto-remediate-open-ssh-rdp/
│   │   ├── event-driven/
│   │   ├── config-rule/
│   │   └── lambda/             # shared Lambda source (Terraform zips this)
│   ├── scp-guardrails/
│   ├── root-activity-alarm/
│   ├── iam-credential-hygiene/
│   ├── ec2-isolation-runbook/
│   └── security-baseline-new-accounts/
│       ├── member-baseline/
│       └── organization-trail/
└── policies/
    └── scp-guardrails/          # standalone SCP JSON, usable without CFN/TF
```

## Templates

### `auto-remediate-open-ssh-rdp`

Automatically revokes security group ingress rules that open **SSH (22)**
or **RDP (3389)** to the entire internet (`0.0.0.0/0` / `::/0`). Ships as
two complementary paths — deploy one or both:

- **`event-driven/`** — EventBridge rule matching CloudTrail's
  `AuthorizeSecurityGroupIngress` event, revokes the offending rule within
  seconds of it being created.
- **`config-rule/`** — AWS Config managed rule (`RESTRICTED_INCOMING_TRAFFIC`)
  + SSM Automation remediation, re-evaluates all security groups on a
  schedule and catches rules that existed before deployment or slipped
  past the event-driven path.

Both paths send an SNS notification on every remediation and share the
same Lambda logic. See each subdirectory's README for deployment
instructions.

### `scp-guardrails`

A library of preventive Service Control Policies: deny root user actions,
deny disabling CloudTrail/Config/GuardDuty/Security Hub, require IMDSv2,
deny leaving the Organization, deny disabling S3 Block Public Access, and
an optional region-restriction policy. Usable as standalone JSON from
`policies/scp-guardrails/`, or deployed/attached to Organizations targets
via `cloudformation/scp-guardrails/` or `terraform/scp-guardrails/`. See
`policies/scp-guardrails/README.md` for full usage of all three.

### `root-activity-alarm`

Fires an SNS notification within seconds of any root user activity —
console sign-in, API call, or AWS service event performed as root. No
Lambda involved; EventBridge invokes SNS directly. A detective complement
to the `deny-root-user` SCP: catches attempts even where the SCP blocks
them, and covers console sign-ins, which SCPs can't prevent.

### `iam-credential-hygiene`

Scans every IAM user's access keys on a schedule and **deactivates**
(never deletes) any key that's too old or unused for too long, notifying
via SNS. Closes one of the most common CIS Benchmark / Wiz / Security Hub
findings automatically instead of relying on someone reviewing a
credential report.

### `ec2-isolation-runbook`

An **on-demand** SSM Automation runbook for incident response: tags a
suspected-compromised instance, snapshots every attached EBS volume for
forensics, swaps its security groups for a fully-isolated one, optionally
stops it, and notifies via SNS. Deliberately not automatic — isolating
the wrong instance on a false positive can itself cause an outage.

### `security-baseline-new-accounts`

Multi-account governance: ensures every account in an OU gets a security
baseline automatically, including accounts created later.

- **`member-baseline/`** — a CloudFormation StackSet (service-managed,
  auto-deployment) that enables GuardDuty, Security Hub, and AWS Config in
  every targeted account.
- **`organization-trail/`** — a single AWS Organization CloudTrail trail
  covering every account automatically. Deployed once, separately from
  the per-account baseline, since CloudTrail rejects a duplicate org trail
  per account.

## CI

GitHub Actions on every push/PR:
- **CloudFormation**: `cfn-lint` + Checkov
- **Terraform**: `terraform fmt -check`, `terraform validate`, `tflint`,
  Checkov

## Contributing

PRs welcome. New templates should:
- Support both AWS commercial and GovCloud partitions
- Include a README with what it does, how it works, and deployment steps
- Pass the existing CI (lint + Checkov) before merge
