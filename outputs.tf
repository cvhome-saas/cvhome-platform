output "console_url" {
  description = "Sign in here. This is the QA path's first step."
  value       = module.store_core.console_url
}

output "urls" {
  description = "Every hostname store-core answers on, and the service behind it."
  value       = module.store_core.urls
}

output "pods" {
  description = "Storefront endpoint and CDN domain per pod."
  value = {
    for key, pod in module.store_pod : key => {
      domain     = pod.domain
      endpoint   = pod.endpoint
      cdn_domain = pod.cdn_domain
      namespace  = pod.namespace
    }
  }
}

output "core_namespace" {
  description = "Cloud Map namespace for store-core. Needed by the app's discovery client."
  value       = module.store_core.namespace
}

output "core_namespace_id" {
  description = <<-EOT
    The value that must replace the hardcoded ns-je7qri6wn7fbsrpn default in the
    application's fargate-config.yml.
  EOT
  value       = module.store_core.namespace_id
}

output "flavour" {
  description = "The resolved flavour, after overrides. Useful for confirming what prod actually got."
  value       = local.flavour
}

output "service_count" {
  description = "Services deployed, as a sanity check against the catalog's 15."
  value = {
    core = length(module.store_core.service_names)
    pod  = length(local.pods) > 0 ? length(values(module.store_pod)[0].service_names) : 0
    pods = length(local.pods)
  }
}
