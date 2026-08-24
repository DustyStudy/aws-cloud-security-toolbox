output "stack_set_name" {
  description = "Name of the member-account-baseline StackSet."
  value       = aws_cloudformation_stack_set.member_baseline.name
}
