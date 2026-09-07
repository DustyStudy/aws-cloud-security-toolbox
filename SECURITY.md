# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this repository, please report it privately — **do not open a public GitHub issue**.

**Preferred method:** Use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability) feature (Security tab → "Report a vulnerability" on this repo).

**Alternative:** Email [YOUR_EMAIL_HERE] with a description of the issue, steps to reproduce, and any relevant logs or templates. Please do not include real AWS account IDs, ARNs, or credentials in your report.

You can expect an initial response within 5 business days.

## Scope

This repository provides general-purpose (not FedRAMP-specific) AWS security CloudFormation and Terraform templates for cloud security engineers, designed to work in both AWS commercial and AWS GovCloud. This includes automated remediation tooling, SCP guardrails, IAM Identity Center auditing, and a Wiz findings bridge. Reports in scope include:

- Logic errors in templates/automation that could weaken security posture (e.g. overly permissive IAM, unintended public exposure, remediation logic that fails open)
- Supply-chain concerns (malicious or unpinned dependencies, GitHub Actions)
- Secrets or credentials accidentally committed to this repo

Out of scope: vulnerabilities in AWS services themselves (report those to AWS), or issues in downstream forks/deployments not present in this repo's source.

## Supported Versions

Only the latest tagged release is actively supported. Older releases may not receive security fixes.

| Version | Supported |
| ------- | --------- |
| Latest release | :white_check_mark: |
| Older releases | :x: |
