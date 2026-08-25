# claude-apps-gateway (CloudFormation)

A reference deployment of the [Claude apps gateway for AWS](https://aws.amazon.com/blogs/machine-learning/introducing-claude-apps-gateway-for-aws/)
— a self-hosted control plane that centralizes identity, policy,
telemetry, and spend caps for Claude Code and Claude Desktop across your
organization, routing inference to Amazon Bedrock. Developers sign in
with your corporate IdP instead of holding per-developer cloud
credentials; the gateway holds the one upstream credential and enforces
model access, tool permissions, and spend limits centrally.

This mirrors [Anthropic's own AWS deployment guide](https://code.claude.com/docs/en/claude-apps-gateway-on-aws)
closely — same IAM policies, security group chain, RDS setup, and ECS
task shape — as CloudFormation. It's a working example for
customer-managed infrastructure, not a supported production deployment;
review and adapt it, same as the source guide says about its own `aws`
CLI walkthrough.

## Why two stacks

`ecr/` and `infrastructure/` are separate stacks because a single
CloudFormation stack can't atomically create an empty ECR repository,
wait for a human to build and push an image into it, and then create an
ECS service that needs that image to exist — the service would never
reach a steady state and CloudFormation would roll the whole stack back,
deleting the ECR repository along with everything else. Deploy `ecr/`
first, push your image, then deploy `infrastructure/`.

## Architecture

- **Amazon ECS on AWS Fargate** running the gateway container
- **Amazon RDS for PostgreSQL** in private subnets, storage-encrypted,
  TLS-only (`rds.force_ssl=1`), holding short-lived sign-in state
- **AWS Secrets Manager** for the JWT signing key, the OIDC client
  secret, and the full Postgres connection string — none of these
  values ever appear in the CloudFormation template or parameter history;
  the master password and connection string are built entirely via
  `{{resolve:secretsmanager:...}}` dynamic references
- **A least-privilege IAM task role** scoped to exactly
  `bedrock:InvokeModel`/`InvokeModelWithResponseStream` on the Claude
  inference-profile and foundation-model ARNs — nothing else
- **An internal Application Load Balancer**, `ipv4`-only (a dual-stack
  internal ALB publishes public-range AAAA records, which Claude Code's
  `/login` private-network check rejects even though the A record is
  private), TLS 1.3-floor SSL policy, 3600s idle timeout for streaming
- **An optional `bedrock-runtime` interface VPC endpoint** so inference
  traffic never leaves the AWS network (on by default —
  `CreateBedrockVpcEndpoint=false` to skip)
- **KMS encryption throughout** — a customer-managed key for Secrets
  Manager, the ECR repository, and the ECS log group; RDS storage
  encryption; access logs delivered to a dedicated, encrypted S3 bucket
- **RDS hardening** — Performance Insights, Enhanced Monitoring,
  automatic minor-version upgrades, IAM database authentication enabled
  (available alongside password auth, not replacing it), PostgreSQL log
  export to CloudWatch, and an optional Multi-AZ toggle
- **ECS/ALB hardening** — Container Insights, a read-only root
  filesystem on the gateway container (with a writable `/tmp` via an
  ephemeral volume), ALB deletion protection, and invalid-header
  dropping

## Prerequisites

Before you start, you need:

- A VPC with at least two private subnets in different Availability
  Zones, with outbound internet access via a NAT gateway (needed for the
  IdP and, if you skip the Bedrock VPC endpoint, Bedrock itself)
- An OIDC identity provider (Okta, Entra ID, Google Workspace, Keycloak,
  or any OIDC-compliant IdP) with a web application registered for the
  gateway — set its redirect URI to `https://<gateway-hostname>/oauth/callback`
  once you've chosen the hostname
- A TLS hostname for the gateway (typically a Route 53 private-hosted-zone
  record aliased to the ALB this stack creates) and an ACM certificate for it
- The AWS CLI v2 and Docker, installed and authenticated locally
- Claude Code v2.1.195+ (the `claude gateway` subcommand), downloaded per
  [Install Claude Code](https://code.claude.com/docs/en/setup) — you need
  the native `linux-x64` binary to build into the image, not the Node install

## Deploying

### Phase 1 — ECR repository

```bash
aws cloudformation deploy \
  --template-file ecr/template.yaml \
  --stack-name claude-gateway-ecr \
  --parameter-overrides RepositoryName=claude-gateway

ECR_URI=$(aws cloudformation describe-stacks --stack-name claude-gateway-ecr \
  --query 'Stacks[0].Outputs[?OutputKey==`EcrRepositoryUri`].OutputValue' --output text)
ECR_KEY_ARN=$(aws cloudformation describe-stacks --stack-name claude-gateway-ecr \
  --query 'Stacks[0].Outputs[?OutputKey==`EcrKeyArn`].OutputValue' --output text)
```

### Phase 2 — build and push the image

```bash
cp gateway.yaml.example gateway.yaml
# Fill in every REPLACE_ME in gateway.yaml: public_url, trusted_proxies,
# oidc.issuer/client_id/allowed_email_domains, upstreams[0].region.

curl -fL --proto '=https' -o rds-global-bundle.pem \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin "$(echo $ECR_URI | cut -d/ -f1)"

docker build --platform=linux/amd64 -t "${ECR_URI}:v1" .
docker push "${ECR_URI}:v1"
```

### Phase 3 — everything else

Choose your gateway's hostname before this step (e.g.
`claude-gateway.internal.example.com`) — it must match the ACM
certificate, your IdP app's redirect URI, and `public_url` in
`gateway.yaml`:

```bash
aws cloudformation deploy \
  --template-file infrastructure/template.yaml \
  --stack-name claude-gateway \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      VpcId=vpc-xxxxxxxx \
      PrivateSubnetIds=subnet-aaaa,subnet-bbbb \
      CorporateCidr=10.0.0.0/8 \
      AcmCertificateArn=arn:aws:acm:us-east-1:123456789012:certificate/xxxx \
      EcrRepositoryUri="$ECR_URI" \
      EcrKeyArn="$ECR_KEY_ARN" \
      ContainerImageTag=v1 \
      OidcClientSecretValue='<your-idp-client-secret>'
```

Then alias your chosen hostname to the stack's `LoadBalancerDnsName`
output in your Route 53 private hosted zone, and update the OIDC app's
redirect URI to match if you hadn't finalized it yet.

Finally, push the gateway URL to developer machines via your MDM's
managed settings file — see
[Set the gateway URL](https://code.claude.com/docs/en/claude-apps-gateway#set-the-gateway-url).

## Parameters (`infrastructure/template.yaml`)

| Parameter | Required | Description |
|---|---|---|
| `VpcId` | Yes | VPC to deploy into |
| `PrivateSubnetIds` | Yes | At least 2 private subnets, different AZs |
| `CorporateCidr` | Yes | CIDR allowed to reach the ALB on 443 |
| `AcmCertificateArn` | Yes | ACM certificate for the gateway hostname |
| `EcrRepositoryUri` | Yes | Output of the `ecr/` stack, after pushing an image |
| `EcrKeyArn` | Yes | `EcrKeyArn` output of the `ecr/` stack - grants the execution role decrypt access to pull the image |
| `ContainerImageTag` | No | Image tag to deploy (default `latest`) |
| `OidcClientSecretValue` | Yes | Your IdP app's OAuth client secret (`NoEcho`) |
| `DesiredCount` | No | Number of gateway tasks (default `1`) |
| `DbInstanceClass` | No | RDS instance class (default `db.t4g.micro`) |
| `DbAllocatedStorageGB` | No | RDS storage in GB (default `20`) |
| `EnableDeletionProtection` | No | RDS + ALB deletion protection (default `true`) |
| `EnableMultiAz` | No | RDS Multi-AZ - roughly doubles RDS cost (default `false`) |
| `CreateBedrockVpcEndpoint` | No | Create the `bedrock-runtime` interface endpoint (default `true`) |

## Notes

- **The gateway never sends telemetry, prompts, or completions to
  Anthropic** unless the Anthropic API is itself a configured upstream —
  this deployment uses Bedrock, so all inference stays inside your AWS
  account's security boundary.
- **Rotating the JWT secret or OIDC client secret** requires a task
  restart to pick up the new value (ECS injects secrets at container
  start, not on a running task) — force a new deployment after rotating.
- **Automatic secret rotation isn't wired up** for any of the four
  secrets in this reference deployment. The DB master password is the
  one with a real, implementable path (AWS's RDS single-user rotation
  Lambda, deployed alongside network access to the database); the JWT
  secret can only be rotated by generating a new value and forcing a new
  ECS deployment; the OIDC client secret requires coordinating with your
  IdP's own admin console, which a Secrets Manager rotation Lambda can't
  do unattended; the Postgres URL secret is a derived string that would
  need regenerating whenever the master password rotates. Each secret's
  `Metadata.checkov.skip` comment in the template repeats this.
- **A `gateway.yaml` edit means a rebuild under a new image tag.** The
  config is baked into the image, and the ECR repository's
  `IMMUTABLE` tag setting means an existing tag can't be silently
  re-pointed at new content anyway.
- **Submit Anthropic's one-time Bedrock use-case form** before the first
  invocation, if no one in your account has already — open the Bedrock
  console's Model catalog, select an Anthropic model, and complete the
  form. See [Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock#1-submit-use-case-details).
- This deployment intentionally omits Route 53 record creation, since
  hosted zone structure varies too much per org to template generically —
  alias your chosen gateway hostname to the ALB's `LoadBalancerDnsName`
  output yourself.
- For an EKS-based deployment instead of ECS Fargate, see
  [the source guide's EKS track](https://code.claude.com/docs/en/claude-apps-gateway-on-aws) —
  this repo doesn't include Kubernetes manifests.
- For per-user/per-group spend caps, model allowlists by IdP group, and
  telemetry fan-out, see the
  [configuration reference](https://code.claude.com/docs/en/claude-apps-gateway-config)
  and expand `gateway.yaml` accordingly (commented-out starting points
  are in `gateway.yaml.example`).
