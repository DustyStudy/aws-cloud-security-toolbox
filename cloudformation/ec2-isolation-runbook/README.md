# ec2-isolation-runbook (CloudFormation)

An on-demand SSM Automation runbook for isolating a suspected-compromised
EC2 instance during incident response. Unlike the other tools in this
repo, this is **not** automatic — you run it deliberately, on a specific
instance, when you've decided it needs to be contained. Auto-triggering
instance isolation on a detection signal risks isolating (or stopping) a
legitimate production instance on a false positive.

## What it does

1. **Tags** the instance (`IsolatedForIR=true`, a timestamp, and your
   incident reference) so it's obvious at a glance in the console.
2. **Snapshots every attached EBS volume** for forensics, before anything
   else touches the instance.
3. **Replaces all of the instance's security groups** with a fully
   isolated one (no inbound rules, no outbound rules) — cutting off
   network access while leaving the instance itself running and
   available for live forensics if you need it.
4. **Optionally stops the instance** (`StopInstance=true`) if you've
   decided containment matters more than live analysis.
5. **Notifies via SNS** with a summary, including the snapshot IDs.

## Deploying

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name ec2-isolation-runbook \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      VpcId=vpc-xxxxxxxx \
      NotificationEmail=you@example.com
```

Deploy **one stack per VPC** you want this available for — the isolation
security group lives in a specific VPC.

Works the same in GovCloud — no partition is hardcoded.

## Running it during an incident

Console: Systems Manager → Automation → Execute automation →
`<stack-name>-IsolateCompromisedInstance` → fill in `InstanceId` (and
optionally `IncidentId` / `StopInstance`) → Execute.

CLI:

```bash
aws ssm start-automation-execution \
  --document-name "<stack-name>-IsolateCompromisedInstance" \
  --parameters "InstanceId=i-0123456789abcdef0,IncidentId=INC-1234,StopInstance=false"
```

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `VpcId` | Yes | VPC to create the isolation security group in |
| `NotificationEmail` | No | Email to subscribe to the SNS topic |

## Runbook parameters (at execution time)

| Parameter | Required | Description |
|---|---|---|
| `InstanceId` | Yes | Instance to isolate |
| `IncidentId` | No | Ticket/incident reference for tagging (default `unspecified`) |
| `StopInstance` | No | Also stop the instance after isolating it (default `false`) |

## Notes

- The isolation security group blocks **all** inbound and outbound traffic
  — including to your VPC endpoints, NAT, everything. This is intentional
  for containment; if you need limited egress (e.g. to a forensics
  collection endpoint) for a specific incident, create a second, more
  permissive isolation SG and pass its ID via the runbook's
  `IsolationSecurityGroupId` parameter at execution time (it defaults to
  the stack's SG but can be overridden per-run).
- Snapshotting happens **before** the network is cut, so a fast-moving
  attacker in an active session isn't tipped off by the SG change first.
- This runbook doesn't touch IAM (e.g. revoking the instance's role
  credentials) — pair it with your incident response process for that.
