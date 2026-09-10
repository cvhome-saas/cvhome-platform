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
  description = "Where ECS tasks run: private behind a NAT, or public with an address each. One place decides."
  value       = local.private_tasks ? [for s in aws_subnet.private : s.id] : [for s in aws_subnet.public : s.id]

  # A service placed in the private subnets before their way out exists fails its image
  # pull and trips the circuit breaker. Everything that reads this waits for the route,
  # which in turn waits for the NAT instance to report ready.
  depends_on = [aws_route.private_nat, aws_vpc_endpoint.s3]
}

output "assign_public_ip" {
  description = "Tasks in public subnets need a public IP to pull images; private ones must not have one."
  value       = !local.private_tasks

  depends_on = [aws_route.private_nat, aws_vpc_endpoint.s3]
}

output "nat_gateway_id" {
  description = "The NAT gateway, when the flavour runs one and compute is up. Null otherwise."
  value       = one(aws_nat_gateway.this[*].id)
}

output "nat_instance_id" {
  description = "The NAT instance, when the flavour runs one and compute is up. Null otherwise."
  value       = one(aws_instance.nat[*].id)
}
