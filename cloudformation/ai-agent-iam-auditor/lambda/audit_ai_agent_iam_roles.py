"""
Scans every IAM role's trust policy for AI/agent service principals
(Bedrock, SageMaker, Amazon Q, etc.) and, for any matching role, checks
its attached and inline policies for overly-broad grants - full admin,
a service-wide wildcard on a sensitive service combined with Resource
"*", or the AdministratorAccess managed policy. Publishes a summary to
SNS. Detective only - no remediation, since automatically stripping an
agent's permissions could break its intended function; a human should
review and right-size these roles deliberately.

The risk this targets: agentic AI workflows often get built by handing
the agent's execution role broad permissions "to get it working," since
the agent may need to call many different APIs depending on what task
it's given. That's a much larger blast radius than a human operator with
the same role, because the agent can be steered (via prompt injection or
just bad task design) into calling any API the role permits, at machine
speed, without a human in the loop to notice something's wrong.

Env vars:
  SNS_TOPIC_ARN               - where to send the audit summary
  AI_SERVICE_PRINCIPALS       - comma-separated list of trust-policy
                                service principals to treat as "AI/agent"
                                roles (default covers Bedrock, SageMaker,
                                Amazon Q)
  SENSITIVE_WILDCARD_SERVICES - comma-separated list of IAM service
                                prefixes where "<service>:*" + Resource "*"
                                is flagged (default: iam, ec2, s3, kms,
                                organizations, sts)
"""

import os
import json
import logging

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

iam = boto3.client("iam")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
AI_SERVICE_PRINCIPALS = [
    s.strip()
    for s in os.environ.get(
        "AI_SERVICE_PRINCIPALS",
        "bedrock.amazonaws.com,sagemaker.amazonaws.com,q.amazonaws.com,qbusiness.amazonaws.com",
    ).split(",")
    if s.strip()
]
SENSITIVE_WILDCARD_SERVICES = [
    s.strip()
    for s in os.environ.get("SENSITIVE_WILDCARD_SERVICES", "iam,ec2,s3,kms,organizations,sts").split(",")
    if s.strip()
]
ADMIN_POLICY_ARN_SUFFIX = "/AdministratorAccess"


def _notify(subject, message):
    if not SNS_TOPIC_ARN:
        logger.info("SNS_TOPIC_ARN not set, skipping notification")
        return
    try:
        sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=message)
    except ClientError:
        logger.exception("Failed to publish SNS notification")


def _principals_from_trust_policy(trust_policy):
    services = set()
    for statement in trust_policy.get("Statement", []):
        principal = statement.get("Principal", {})
        if not isinstance(principal, dict):
            continue
        svc = principal.get("Service")
        if svc is None:
            continue
        if isinstance(svc, str):
            services.add(svc)
        elif isinstance(svc, list):
            services.update(svc)
    return services


def _matching_ai_principals(trust_policy):
    services = _principals_from_trust_policy(trust_policy)
    return services.intersection(AI_SERVICE_PRINCIPALS)


def _as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def _statement_is_risky(statement):
    if statement.get("Effect") != "Allow":
        return None

    actions = [a.lower() for a in _as_list(statement.get("Action"))]
    resources = _as_list(statement.get("Resource"))
    has_wildcard_resource = "*" in resources

    if "*" in actions:
        return "full wildcard action ('*')"

    if has_wildcard_resource:
        for action in actions:
            if ":" not in action:
                continue
            service, _, rest = action.partition(":")
            if rest == "*" and service in SENSITIVE_WILDCARD_SERVICES:
                return f"service-wide wildcard action ({action}) with Resource '*'"

    return None


def _evaluate_policy_document(doc, source_label, findings):
    for statement in doc.get("Statement", []):
        # Statement can be a single dict or (rarely) handled elsewhere as a list -
        # list_role_policies/get_role_policy always returns a dict with Statement
        # being a list already, but guard just in case a single-statement dict slips through.
        if isinstance(statement, dict):
            reason = _statement_is_risky(statement)
            if reason:
                findings.append({"source": source_label, "sid": statement.get("Sid", "(no Sid)"), "reason": reason})


def _evaluate_role(role_name):
    findings = []

    try:
        attached = iam.list_attached_role_policies(RoleName=role_name).get("AttachedPolicies", [])
    except ClientError:
        logger.exception("Failed to list attached policies for role %s", role_name)
        attached = []

    for policy in attached:
        if policy.get("PolicyArn", "").endswith(ADMIN_POLICY_ARN_SUFFIX):
            findings.append(
                {"source": f"managed policy {policy['PolicyName']}", "sid": "(whole policy)", "reason": "AdministratorAccess attached"}
            )
            continue
        try:
            policy_arn = policy["PolicyArn"]
            version_id = iam.get_policy(PolicyArn=policy_arn)["Policy"]["DefaultVersionId"]
            doc = iam.get_policy_version(PolicyArn=policy_arn, VersionId=version_id)["PolicyVersion"]["Document"]
            _evaluate_policy_document(doc, f"managed policy {policy['PolicyName']}", findings)
        except ClientError:
            logger.exception("Failed to evaluate managed policy %s for role %s", policy.get("PolicyName"), role_name)

    try:
        inline_names = iam.list_role_policies(RoleName=role_name).get("PolicyNames", [])
    except ClientError:
        logger.exception("Failed to list inline policies for role %s", role_name)
        inline_names = []

    for name in inline_names:
        try:
            doc = iam.get_role_policy(RoleName=role_name, PolicyName=name)["PolicyDocument"]
            _evaluate_policy_document(doc, f"inline policy {name}", findings)
        except ClientError:
            logger.exception("Failed to evaluate inline policy %s for role %s", name, role_name)

    return findings


def _iter_roles():
    paginator = iam.get_paginator("list_roles")
    for page in paginator.paginate():
        for role in page.get("Roles", []):
            yield role


def lambda_handler(event, context):
    logger.info("Starting AI/agent IAM privilege audit")
    flagged_roles = []

    for role in _iter_roles():
        role_name = role["RoleName"]
        trust_policy = role.get("AssumeRolePolicyDocument", {})
        matched_principals = _matching_ai_principals(trust_policy)
        if not matched_principals:
            continue

        findings = _evaluate_role(role_name)
        if findings:
            flagged_roles.append(
                {
                    "role_name": role_name,
                    "role_arn": role.get("Arn"),
                    "trusted_by": sorted(matched_principals),
                    "findings": findings,
                }
            )

    if flagged_roles:
        lines = []
        for r in flagged_roles:
            lines.append(f"\nRole: {r['role_name']} ({r['role_arn']})")
            lines.append(f"  Trusted by: {', '.join(r['trusted_by'])}")
            for f in r["findings"]:
                lines.append(f"  - [{f['source']}] {f['sid']}: {f['reason']}")

        _notify(
            subject=f"AI agent IAM audit: {len(flagged_roles)} over-permissioned role(s) found",
            message=(
                "The following IAM roles are trusted by an AI/agent service "
                "(Bedrock, SageMaker, Amazon Q, etc.) and carry broader "
                "permissions than typically necessary. Review and "
                "right-size these deliberately - this audit does not "
                "modify anything.\n" + "\n".join(lines)
            ),
        )
    else:
        logger.info("No over-permissioned AI/agent roles found")

    return {
        "statusCode": 200,
        "body": json.dumps({"flagged_role_count": len(flagged_roles), "flagged_roles": [r["role_name"] for r in flagged_roles]}),
    }
