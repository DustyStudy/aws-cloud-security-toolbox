# Deploy from the Organizations management account, or a registered
# delegated administrator account for CloudFormation StackSets (set
# call_as = "DELEGATED_ADMIN" in that case). Requires trusted access for
# CloudFormation StackSets enabled for the Organization:
#   aws organizations enable-aws-service-access \
#     --service-principal member.org.stacksets.cloudformation.amazonaws.com

resource "aws_cloudformation_stack_set" "member_baseline" {
  name             = "${var.name_prefix}-member-baseline"
  description      = "Enables GuardDuty, Security Hub, and AWS Config in every targeted account."
  permission_model = "SERVICE_MANAGED"
  call_as          = var.call_as
  capabilities     = ["CAPABILITY_NAMED_IAM"]

  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  operation_preferences {
    max_concurrent_percentage    = 100
    failure_tolerance_percentage = 20
  }

  # See baseline-template.yaml for the per-account resources. Ordinary CFN
  # intrinsic functions in it are evaluated per-account by CloudFormation
  # when it provisions each stack instance.
  template_body = file("${path.module}/baseline-template.yaml")
}

resource "aws_cloudformation_stack_set_instance" "member_baseline" {
  for_each = toset(var.regions)

  stack_set_name = aws_cloudformation_stack_set.member_baseline.name
  call_as        = var.call_as
  region         = each.value

  deployment_targets {
    organizational_unit_ids = var.target_organizational_unit_ids
  }

  operation_preferences {
    max_concurrent_percentage    = 100
    failure_tolerance_percentage = 20
  }
}
