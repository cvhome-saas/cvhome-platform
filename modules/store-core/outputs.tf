output "namespace" {
  description = "Cloud Map namespace. Pod services resolve the shared otel-collector here."
  value       = aws_service_discovery_private_dns_namespace.this.name
}

output "namespace_id" {
  value = aws_service_discovery_private_dns_namespace.this.id
}

output "alb_dns_name" {
  description = "Null while hibernated — the load balancer is one of the hourly things that goes."
  value       = one(aws_lb.this[*].dns_name)
}

output "console_url" {
  description = "Where a human signs in."
  value       = "https://console-ui.${var.domain}"
}

output "urls" {
  description = <<-EOT
    Every hostname this layer answers on, derived from the catalog. Still reported while
    hibernated: these are what the environment will answer on once woken, and they do
    not change across a hibernate/wake cycle because the records are aliases.
  EOT
  value       = { for host, service in local.records : host => service }
}

output "database_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "service_names" {
  value = sort(keys(module.service))
}

# ---------------------------------------------------------------- for the dashboard
#
# The identifiers CloudWatch names this layer's default metrics by. Null or empty
# while hibernated, like the resources themselves.

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "alb_arn_suffix" {
  description = "The LoadBalancer dimension of AWS/ApplicationELB metrics. Null while hibernated."
  value       = one(aws_lb.this[*].arn_suffix)
}

output "target_group_arn_suffixes" {
  description = "The TargetGroup dimension per ALB-fronted service."
  value       = { for name, tg in aws_lb_target_group.service : name => tg.arn_suffix }
}

output "db_identifier" {
  value = aws_db_instance.this.identifier
}

output "log_group_names" {
  value = { for name, svc in module.service : name => svc.log_group_name }
}
