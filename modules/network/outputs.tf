output "vpc_id" {
  value = aws_vpc.this.id
}

output "cidr_block" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "database_subnet_group_name" {
  value = aws_db_subnet_group.this.name
}

output "task_subnet_ids" {
  description = "Where ECS tasks run — private under prod, public below it. One place decides."
  value       = var.private_tasks ? [for s in aws_subnet.private : s.id] : [for s in aws_subnet.public : s.id]
}

output "assign_public_ip" {
  description = "Tasks in public subnets need a public IP to pull images; private ones must not have one."
  value       = !var.private_tasks
}
