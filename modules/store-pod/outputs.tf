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
  value = aws_db_instance.this.endpoint
}

output "service_names" {
  value = sort(keys(module.service))
}
