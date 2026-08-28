output "namespace" {
  description = "Cloud Map namespace. Pod services resolve the shared otel-collector here."
  value       = aws_service_discovery_private_dns_namespace.this.name
}

output "namespace_id" {
  value = aws_service_discovery_private_dns_namespace.this.id
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "console_url" {
  description = "Where a human signs in."
  value       = "https://console-ui.${var.domain}"
}

output "urls" {
  description = "Every hostname this layer answers on, derived from the catalog."
  value       = { for host, service in local.records : host => service }
}

output "database_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "service_names" {
  value = sort(keys(module.service))
}
