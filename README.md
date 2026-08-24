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
│   └── auto-remediate-open-ssh-rdp/
│       ├── event-driven/       # EventBridge + CloudTrail, near real-time
│       ├── config-rule/        # AWS Config + SSM Automation, catches drift
│       └── lambda/             # shared Lambda source (CFN's own copy)
└── terraform/
    └── auto-remediate-open-ssh-rdp/
        ├── event-driven/
        ├── config-rule/
        └── lambda/              # shared Lambda source (Terraform zips this)
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
