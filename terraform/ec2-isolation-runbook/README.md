# ec2-isolation-runbook (Terraform)

An on-demand SSM Automation runbook for isolating a suspected-compromised
EC2 instance during incident response. This is **not** automatic — you run
it deliberately, on a specific instance, when you've decided it needs to
be contained.

## What it does

1. **Tags** the instance (`IsolatedForIR=true`, a timestamp, and your
   incident reference).
2. **Snapshots every attached EBS volume** for forensics, before anything
   else touches the instance.
3. **Replaces all of the instance's security groups** with a fully
   isolated one (no inbound, no outbound) — cutting off network access
   while leaving the instance running for live forensics if needed.
4. **Optionally stops the instance** (`StopInstance=true`).
5. **Notifies via SNS** with a summary, including snapshot IDs.

## Usage

```hcl
module "ec2_isolation" {
  source = "github.com/DustyStudy/aws-cloud-security-toolbox//terraform/ec2-isolation-runbook"

  vpc_id              = "vpc-xxxxxxxx"
  notification_email  = "you@example.com"
}
```

Use **one module instance per VPC** you want this available for — the
isolation security group lives in a specific VPC. Works the same in
GovCloud.

## Running it during an incident

```bash
aws ssm start-automation-execution \
  --document-name "$(terraform output -raw runbook_name)" \
  --parameters "InstanceId=i-0123456789abcdef0,IncidentId=INC-1234,StopInstance=false"
```

Or via the console: Systems Manager → Automation → Execute automation.

## Inputs

| Name | Description | Default |
|---|---|---|
| `name_prefix` | Prefix for all resource names | `ec2-isolation` |
| `vpc_id` | VPC to create the isolation security group in | — (required) |
| `notification_email` | Email to subscribe to the SNS topic (optional) | `""` |

## Runbook parameters (at execution time)

| Parameter | Required | Description |
|---|---|---|
| `InstanceId` | Yes | Instance to isolate |
| `IncidentId` | No | Ticket/incident reference for tagging (default `unspecified`) |
| `StopInstance` | No | Also stop the instance after isolating it (default `false`) |

## Outputs

| Name | Description |
|---|---|
| `runbook_name` | Name of the SSM Automation document |
| `isolation_security_group_id` | ID of the isolation security group |
| `sns_topic_arn` | ARN of the SNS notification topic |

## Notes

- The isolation SG blocks **all** inbound and outbound traffic. If a
  specific incident needs limited egress (e.g. to a forensics collection
  endpoint), create a second SG and pass its ID via the runbook's
  `IsolationSecurityGroupId` parameter at execution time.
- Snapshotting happens **before** the network is cut, so a fast-moving
  attacker isn't tipped off by the SG change first.
- Doesn't touch IAM (e.g. revoking the instance's role credentials) —
  pair with your incident response process for that.
