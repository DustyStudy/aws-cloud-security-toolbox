"""
Receives Wiz webhook deliveries (Settings -> Integrations -> Webhook, fired
by a Policies -> Automation Rule) via API Gateway, and bridges them into
this repo's existing patterns: an SNS notification matching every other
module here, and - optionally - an invocation of one of this repo's own
remediation Lambdas when a finding matches a configured mapping.

This module is deliberately schema-tolerant rather than schema-assuming.
Wiz's outbound webhook JSON shape isn't something this repo can verify
against a live tenant, and it can change between Wiz product versions.
Hardcoding field paths that turn out wrong would fail silently - worse
than not having this tool at all. Instead:

  - The raw payload (truncated) is always included in the SNS message.
  - Which fields to treat as "severity" / "title" / "resource" are
    dot-notation paths read from environment variables, not hardcoded.
  - Until you set those paths to match your real payload, everything
    still gets forwarded to SNS with an "UNKNOWN" placeholder where a
    field couldn't be resolved - fails open on notification, not silent.

Auth model: Wiz's basic Webhook integration (as of this writing) only
lets you configure a destination URL, not custom headers or payload
signing. So instead of verifying a header, this Lambda expects a long
random secret token as the last path segment of the webhook URL itself
(e.g. https://.../wiz-webhook/<secret>) - the same "unguessable URL"
pattern most webhook-only integrations rely on. The secret is generated
by the CloudFormation/Terraform deploy and stored in Secrets Manager;
see the module README for how to retrieve it and build the full URL to
paste into Wiz.

Env vars:
  SNS_TOPIC_ARN              - where to publish the bridged notification
  WEBHOOK_SECRET_ARN         - Secrets Manager secret holding the token
                                that must match the URL path segment
  MIN_SEVERITY               - lowest severity to notify on: CRITICAL,
                                HIGH, MEDIUM, LOW, or INFORMATIONAL
                                (default HIGH). A finding whose severity
                                can't be resolved is always notified,
                                regardless of this setting - fail open.
  SEVERITY_FIELD_PATH        - dot-notation path to the severity field
                                in the Wiz payload (default "severity")
  TITLE_FIELD_PATH           - dot-notation path to a human-readable
                                title/rule-name field (default "title")
  RESOURCE_FIELD_PATH        - dot-notation path to a resource
                                object/identifier field (default
                                "primaryResource" - an object in Wiz's
                                schema, rendered as JSON in the report
                                since its internal shape isn't assumed)
  REMEDIATION_LAMBDA_MAP     - JSON object string mapping a title value
                                (as resolved by TITLE_FIELD_PATH) to a
                                Lambda function ARN in this account to
                                invoke with the normalized finding as its
                                payload, e.g. wiring a specific Wiz rule
                                name to this repo's own
                                auto-remediate-open-ssh-rdp Lambda.
                                Default "{}" (no mappings - notify only).
"""

import os
import json
import hmac
import logging

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

secretsmanager = boto3.client("secretsmanager")
sns = boto3.client("sns")
lambda_client = boto3.client("lambda")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
WEBHOOK_SECRET_ARN = os.environ.get("WEBHOOK_SECRET_ARN")
MIN_SEVERITY = os.environ.get("MIN_SEVERITY", "HIGH").upper()
SEVERITY_FIELD_PATH = os.environ.get("SEVERITY_FIELD_PATH", "severity")
TITLE_FIELD_PATH = os.environ.get("TITLE_FIELD_PATH", "title")
RESOURCE_FIELD_PATH = os.environ.get("RESOURCE_FIELD_PATH", "primaryResource")

SEVERITY_RANK = {
    "CRITICAL": 5,
    "HIGH": 4,
    "MEDIUM": 3,
    "LOW": 2,
    "INFORMATIONAL": 1,
}

MAX_RAW_PAYLOAD_CHARS = 2000

# Cached across warm Lambda invocations to avoid a Secrets Manager call
# on every webhook delivery. Cleared automatically on cold start.
_cached_secret = None


def _get_expected_secret():
    global _cached_secret
    if _cached_secret is not None:
        return _cached_secret
    try:
        response = secretsmanager.get_secret_value(SecretId=WEBHOOK_SECRET_ARN)
        _cached_secret = response["SecretString"]
        return _cached_secret
    except ClientError:
        logger.exception("Failed to retrieve webhook secret from Secrets Manager")
        return None


def _get_path(obj, path, default=None):
    """Resolve a dot-notation path (e.g. "resource.cloudPlatform.name")
    against a nested dict. Missing keys or a non-dict along the way just
    return the default - never raises."""
    current = obj
    for part in path.split("."):
        if not isinstance(current, dict) or part not in current:
            return default
        current = current[part]
    return current if current is not None else default


def _http_response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _invoke_remediation_if_mapped(title, finding):
    mapping_raw = os.environ.get("REMEDIATION_LAMBDA_MAP", "{}")
    try:
        mapping = json.loads(mapping_raw)
    except (TypeError, ValueError):
        logger.exception("REMEDIATION_LAMBDA_MAP is not valid JSON - skipping")
        return None

    target_arn = mapping.get(title)
    if not target_arn:
        return None

    try:
        lambda_client.invoke(
            FunctionName=target_arn,
            InvocationType="Event",  # fire-and-forget - don't block the webhook response on it
            Payload=json.dumps({"source": "wiz-finding-bridge", "finding": finding}).encode("utf-8"),
        )
        return target_arn
    except ClientError:
        logger.exception("Failed to invoke mapped remediation Lambda %s for title %r", target_arn, title)
        return None


def lambda_handler(event, context):
    # API Gateway HTTP API, payload format 2.0
    path_params = event.get("pathParameters") or {}
    provided_secret = path_params.get("secretToken", "")

    expected_secret = _get_expected_secret()
    if not expected_secret or not hmac.compare_digest(provided_secret, expected_secret):
        logger.warning("Rejected webhook delivery with an invalid or missing secret token")
        return _http_response(401, {"message": "unauthorized"})

    raw_body = event.get("body", "") or ""
    try:
        payload = json.loads(raw_body)
        if not isinstance(payload, dict):
            raise ValueError("Payload was valid JSON but not a JSON object")
    except (TypeError, ValueError):
        logger.exception("Webhook body was not valid JSON")
        # Still 200 - a malformed body isn't something Wiz should retry
        # forever, and we don't want retry storms from a bad delivery.
        return _http_response(200, {"message": "received, but body was not valid JSON - not processed"})

    def _stringify(value):
        # Wiz payloads nest objects/arrays for some fields (e.g. a
        # "primaryResource" object rather than a flat string) - render
        # those as compact JSON instead of Python's str(dict) repr, which
        # uses single quotes and isn't valid JSON, so the report stays
        # copy-pasteable.
        if isinstance(value, (dict, list)):
            return json.dumps(value)
        return str(value)

    severity = _stringify(_get_path(payload, SEVERITY_FIELD_PATH, "UNKNOWN")).upper()
    title = _stringify(_get_path(payload, TITLE_FIELD_PATH, "unknown finding"))
    resource = _stringify(_get_path(payload, RESOURCE_FIELD_PATH, "unknown resource"))

    severity_rank = SEVERITY_RANK.get(severity)
    min_rank = SEVERITY_RANK.get(MIN_SEVERITY, SEVERITY_RANK["HIGH"])

    # Fail open: an unresolved severity (rank is None) is always notified,
    # so a wrong SEVERITY_FIELD_PATH surfaces as noise you'll notice and
    # fix, not as findings silently dropped below a threshold you can't see.
    if severity_rank is not None and severity_rank < min_rank:
        logger.info("Below MIN_SEVERITY (%s < %s) - not notifying: %s", severity, MIN_SEVERITY, title)
        return _http_response(200, {"message": "received, below MIN_SEVERITY threshold"})

    invoked_arn = _invoke_remediation_if_mapped(title, payload)

    raw_excerpt = raw_body[:MAX_RAW_PAYLOAD_CHARS]
    if len(raw_body) > MAX_RAW_PAYLOAD_CHARS:
        raw_excerpt += "... (truncated)"

    message_lines = [
        f"Severity: {severity}{'' if severity_rank is not None else ' (unresolved - check SEVERITY_FIELD_PATH)'}",
        f"Title: {title}",
        f"Resource: {resource}",
    ]
    if invoked_arn:
        message_lines.append(f"Forwarded to remediation Lambda: {invoked_arn}")
    message_lines.append("\nRaw payload (use this to tune *_FIELD_PATH env vars if fields above look wrong):")
    message_lines.append(raw_excerpt)

    if SNS_TOPIC_ARN:
        try:
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"Wiz finding: {title}"[:100],
                Message="\n".join(message_lines),
            )
        except ClientError:
            logger.exception("Failed to publish SNS notification")
    else:
        logger.info("SNS_TOPIC_ARN not set, skipping notification")

    return _http_response(200, {"message": "received"})
