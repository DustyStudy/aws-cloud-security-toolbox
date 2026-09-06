# ai-ml-guardrails (CloudFormation)

Deploys the SCP library in [`policies/ai-ml-guardrails/`](../../policies/ai-ml-guardrails/)
and attaches them to the Organizations targets (OUs, accounts, or the
root) you specify — protects Bedrock's audit trail, optionally restricts
which foundation models can be invoked, and locks down SageMaker notebook
instances (no direct internet access, no root access, VPC + KMS
required).

Full policy descriptions, parameters, and deployment commands live in
[`policies/ai-ml-guardrails/README.md`](../../policies/ai-ml-guardrails/README.md#using-cloudformation) —
this directory just holds the template (`template.yaml`).

Quick start:

```bash
aws cloudformation deploy \
  --template-file cloudformation/ai-ml-guardrails/template.yaml \
  --stack-name ai-ml-guardrails \
  --parameter-overrides \
      TargetIds=ou-abcd-11111111,123456789012 \
      EnableRestrictBedrockFoundationModels=true \
      AllowedBedrockModelPatterns=anthropic.claude*,amazon.titan*
```

`EnableRestrictBedrockFoundationModels` is off by default — turn it on
only after populating the model allow-list, or you'll block all Bedrock
usage in the account.
