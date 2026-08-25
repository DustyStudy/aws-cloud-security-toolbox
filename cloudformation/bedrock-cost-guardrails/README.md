# bedrock-cost-guardrails (CloudFormation)

Guards against the most common real-world agentic AI incident: not a
breach, but an agent stuck in a loop calling itself or a tool
repeatedly, running up a large bill overnight before anyone notices.
Two complementary AWS-native cost controls, both scoped to Amazon
Bedrock — no Lambda involved.

## What this deploys

1. **A monthly budget** (`AWS::Budgets::Budget`) with a hard USD ceiling
   for Bedrock spend, notifying at 80% of actual spend and 100% of
   forecasted spend. Predictable, threshold-based — you set the number.
2. **Cost Anomaly Detection** (`AWS::CE::AnomalyMonitor` +
   `AWS::CE::AnomalySubscription`), scoped to the Bedrock service via a
   custom monitor. This is ML-based against your account's own
   historical spend pattern, so it can catch a spike *before* it reaches
   the budget ceiling — the difference matters because a runaway agent
   loop overnight can blow past a monthly threshold in hours.

Both notify the same SNS topic.

## Deploying

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name bedrock-cost-guardrails \
  --parameter-overrides \
      NotificationEmail=you@example.com \
      MonthlyBudgetLimitUSD=500 \
      AnomalyThresholdUSD=50
```

Works the same in GovCloud, assuming Bedrock is available in your
GovCloud region.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `NotificationEmail` | No | Email to subscribe to the SNS topic |
| `MonthlyBudgetLimitUSD` | No | Monthly USD ceiling for Bedrock spend (default `500`) |
| `AnomalyThresholdUSD` | No | Dollar-impact threshold for an immediate anomaly alert (default `50`) |

## Notes

- **Cost Anomaly Detection notifications require `Frequency: IMMEDIATE`
  to use SNS** — `DAILY`/`WEEKLY` frequencies only support email
  subscribers. This template uses `IMMEDIATE` so alerts reach SNS (and
  anything you wire downstream of it — Slack, PagerDuty, a Lambda) as
  soon as an anomaly is detected, not batched into a daily digest.
- Cost Anomaly Detection needs some baseline spend history to establish
  what's "normal" before it can flag deviations — expect it to be less
  useful in the first few weeks after Bedrock usage starts.
- The budget's `CostFilters` scope it to the "Amazon Bedrock" service
  specifically — spend from SageMaker, Bedrock Agents' underlying Lambda
  invocations, or other AI infrastructure isn't included. Duplicate this
  template with a different `CostFilters` value if you want the same
  pattern for other services.
- Set `MonthlyBudgetLimitUSD` and `AnomalyThresholdUSD` based on your
  actual expected usage — defaults are a starting point, not a
  recommendation for your workload's scale.
