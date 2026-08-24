# scp-guardrails

A library of preventive Service Control Policies (SCPs) for common AWS
guardrails. Deploy them individually as raw JSON, or use the
CloudFormation/Terraform to create and attach them to Organizations
targets (OUs, accounts, or the root) in one shot.

SCPs are an **Organizations** feature — deploy from the management
account (or a delegated Organizations admin account). They apply
account-wide and can't be overridden by IAM policies in member accounts,
which is what makes them a guardrail rather than just another permission.

## Policies included

| File | What it denies |
|---|---|
| `deny-root-user.json` | Any action taken as the account root user |
| `deny-disable-security-services.json` | Disabling/stopping CloudTrail, Config, GuardDuty, or Security Hub |
| `require-imdsv2.json` | Launching or modifying EC2 instances without IMDSv2 required |
| `deny-leave-organization.json` | A member account leaving the Organization |
| `deny-disable-s3-public-access-block.json` | Disabling S3 Block Public Access at the account or bucket level |
| `restrict-regions.json` | Actions outside an allow-listed set of regions (global services exempted) |

`restrict-regions.json` has `REPLACE_WITH_ALLOWED_REGION_*` placeholders —
edit those (or use the CloudFormation/Terraform, which templates the
region list for you) before attaching it. It's also the one most likely
to need periodic upkeep: AWS occasionally adds new global services, and
this list should be checked against AWS's own SCP examples over time.

## Using the raw JSON directly

Each file in this directory (`policies/scp-guardrails/`) is a complete,
standalone SCP. Attach any of them via the console (Organizations →
Policies → Service control policies → Create policy → paste JSON) or CLI:

```bash
aws organizations create-policy \
  --name deny-root-user \
  --type SERVICE_CONTROL_POLICY \
  --content file://policies/scp-guardrails/deny-root-user.json

aws organizations attach-policy \
  --policy-id p-xxxxxxxx \
  --target-id ou-xxxx-xxxxxxxx
```

## Using CloudFormation

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

Each policy has its own `Enable*` parameter (default `true`, except
`EnableRestrictRegions` which defaults `false` until you've reviewed the
region list). Set any to `false` to skip creating that policy.

## Using Terraform

```hcl
module "scp_guardrails" {
  source = "github.com/DustyStudy/aws-cloud-security-toolbox//terraform/scp-guardrails"

  target_ids              = ["ou-abcd-11111111", "123456789012"]
  enable_restrict_regions = true
  allowed_regions          = ["us-gov-west-1", "us-gov-east-1"]
}
```

Every policy has a matching `enable_*` boolean variable (see
`variables.tf`), same defaults as the CloudFormation parameters.

## GovCloud notes

- GovCloud accounts belong to their own separate Organization (linked to
  a commercial-account Organization but managed independently) — deploy
  this stack/module **within the GovCloud org's management account**,
  not the linked commercial one.
- `restrict-regions.json` is the one place you should always customize:
  set `AllowedRegions`/`allowed_regions` to your GovCloud region(s), e.g.
  `us-gov-west-1,us-gov-east-1`.

## Before enabling in production

SCPs are enforced immediately once attached — test in a non-production OU
first. `deny-root-user` and `restrict-regions` in particular are worth a
dry run: confirm break-glass procedures don't rely on root, and that
every service/region your workloads actually use is accounted for in the
region allow-list and the global-service exemption list.
