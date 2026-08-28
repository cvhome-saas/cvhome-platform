output "service_name" {
  description = "ECS service name — also the Cloud Map name, so lb://<name> resolves to it."
  value       = aws_ecs_service.this.name
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}
