output "namespace" {
  value = aws_service_discovery_private_dns_namespace.this.name
}

output "domain" {
  description = "The pod's storefront hostname."
  value       = local.pod_fqdn
}

output "endpoint" {
  value = local.endpoint
}

output "cdn_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "database_endpoint" {
  description = "The pod's own database. Null when it shares store-core's, which core reports."
  value       = var.database_shared ? null : aws_db_instance.this[0].endpoint
}

output "database_shared" {
  description = "Whether this pod's services use store-core's database rather than their own."
  value       = var.database_shared
}

output "service_names" {
  value = sort(keys(module.service))
}

# ---------------------------------------------------------------- for the dashboard
#
# The identifiers CloudWatch names this pod's default metrics by. Null or empty
# while hibernated, like the resources themselves.

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "nlb_arn_suffix" {
  description = "The LoadBalancer dimension of AWS/NetworkELB metrics. Null while hibernated."
  value       = one(aws_lb.this[*].arn_suffix)
}

output "nlb_target_group_arn_suffixes" {
  description = "The TargetGroup dimension per NLB listener port."
  value       = { for port, tg in aws_lb_target_group.spg : port => tg.arn_suffix }
}

output "db_identifier" {
  description = "Null when the pod shares store-core's database; the dashboard shows that one under store-core."
  value       = var.database_shared ? null : aws_db_instance.this[0].identifier
}

output "cdn_distribution_id" {
  value = aws_cloudfront_distribution.cdn.id
}

output "log_group_names" {
  value = { for name, svc in module.service : name => svc.log_group_name }
}
