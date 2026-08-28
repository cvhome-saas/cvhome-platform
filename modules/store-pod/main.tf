locals {
  layer     = "store-pod-${var.pod.short}"
  prefix    = "${var.project}-${var.env}"
  namespace = "${local.layer}.${var.project}-${var.env}.lcl"

  profiles = join(",", compact(["fargate", var.test_stores ? "test-stores" : ""]))

  pod_fqdn = "${var.pod.domain}.${var.domain}"
  endpoint = "https://${local.pod_fqdn}"

  # ------------------------------------------------------------------ env, once
  #
  # store-pod-cluster.tf was 654 lines because these ~25 variables were pasted into
  # six service blocks. Here they are written once. Adding a seventh Spring service
  # costs a catalog entry and nothing else.

  # Telemetry crosses into the core namespace: one collector per environment, not one
  # per pod. Both namespaces are private hosted zones on the same VPC, so this resolves.
  otlp_endpoint = "http://otel-collector.${var.core_namespace}"

  # No endpoint when no collector is deployed — otherwise dev pods retry gRPC exports
  # to a service that does not exist, forever.
  otel_spring_env = var.flavour.monitoring ? [{ name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "${local.otlp_endpoint}:4318" }] : []
  otel_grpc_env = var.flavour.monitoring ? [
    { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "grpc" },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "${local.otlp_endpoint}:4317" },
  ] : []

  # Every pod service is discoverable at this pod's namespace. Generated from the
  # catalog, so the legacy inconsistency — payment listing PAYMENT but not CUA, and
  # every other service listing a different subset — cannot recur.
  #
  # Hyphens are preserved deliberately: these are map keys in
  # Map<String, ServiceDomain>, and Spring splits environment variable names on "_",
  # so LANDING_UI would bind services.landing.ui rather than services["landing-ui"].
  service_namespace_env = [
    for name, _ in var.services :
    { name = "COM_ASREVO_CVHOME_SERVICES_${upper(name)}_NAMESPACE", value = local.namespace }
  ]

  common_spring_env = concat([
    { name = "SPRING_PROFILES_ACTIVE", value = local.profiles },
    { name = "OTEL_SDK_DISABLED", value = tostring(!var.flavour.monitoring) },
    { name = "COM_ASREVO_CVHOME_APP_DOMAIN", value = var.domain },
    { name = "COM_ASREVO_CVHOME_POD_DOMAIN", value = local.pod_fqdn },
    { name = "COM_ASREVO_CVHOME_SERVICES_STORE-CORE-GATEWAY_SCHEMA", value = "https" },
    { name = "COM_ASREVO_CVHOME_SERVICES_STORE-CORE-GATEWAY_PORT", value = "443" },
    { name = "COM_ASREVO_CVHOME_SERVICES_UAA_SCHEMA", value = "https" },
    { name = "COM_ASREVO_CVHOME_SERVICES_UAA_PORT", value = "443" },
    { name = "COM_ASREVO_CVHOME_SERVICES_SPG_SCHEMA", value = "https" },
    { name = "COM_ASREVO_CVHOME_SERVICES_SPG_PORT", value = "443" },
    { name = "SPRING_CLOUD_ECS_DISCOVERY_NAMESPACE", value = local.namespace },
    # Underscore, not the legacy "NAMESPACE-ID": a hyphen is not a valid POSIX
    # environment variable name, and this is the form Spring relaxed binding expects.
    { name = "SPRING_CLOUD_ECS_DISCOVERY_NAMESPACE_ID", value = aws_service_discovery_private_dns_namespace.this.id },
    { name = "COM_ASREVO_CVHOME_POD-INFO_POD_ID", value = var.pod.id },
    { name = "COM_ASREVO_CVHOME_POD-INFO_POD_NAME", value = var.pod.name },
    { name = "COM_ASREVO_CVHOME_POD-INFO_POD_ENDPOINT_ENDPOINT", value = local.endpoint },
    { name = "COM_ASREVO_CVHOME_POD-INFO_POD_ENDPOINT_TYPE", value = "EXTERNAL" },
    { name = "COM_ASREVO_CVHOME_POD-INFO_POD_DOMAIN", value = local.pod_fqdn },
  ], local.otel_spring_env, local.service_namespace_env)

  cdn_env = [
    { name = "COM_ASREVO_CVHOME_CDN_STORAGE_PROVIDER", value = "S3" },
    { name = "COM_ASREVO_CVHOME_CDN_STORAGE_BUCKET", value = aws_s3_bucket.cdn.id },
    { name = "COM_ASREVO_CVHOME_CDN_BASE-PATH", value = "https://${aws_cloudfront_distribution.cdn.domain_name}" },
  ]

  database_env = [
    { name = "SPRING_DATASOURCE_DATABASE", value = aws_db_instance.this.db_name },
    { name = "SPRING_DATASOURCE_HOST", value = aws_db_instance.this.address },
    { name = "SPRING_DATASOURCE_PORT", value = tostring(aws_db_instance.this.port) },
    { name = "SPRING_DATASOURCE_USERNAME", value = aws_db_instance.this.username },
  ]

  database_secret = [
    { name = "SPRING_DATASOURCE_PASSWORD", valueFrom = "${aws_db_instance.this.master_user_secret[0].secret_arn}:password::" },
  ]

  node_env = concat(
    [{ name = "OTEL_SDK_DISABLED", value = tostring(!var.flavour.monitoring) }],
    local.otel_grpc_env,
  )

  # Caddy's own configuration, not Spring's.
  caddy_env = concat([
    { name = "NAMESPACE", value = local.namespace },
    { name = "CERT_BUCKET", value = aws_s3_bucket.certs.id },
    { name = "CERT_BUCKET_REGION", value = aws_s3_bucket.certs.region },
    { name = "DOMAIN_LOOKUP_TTL", value = var.env == "prod" ? "5m" : "1m" },
    { name = "OTEL_SERVICE_NAME", value = "spg" },
  ], local.otel_grpc_env)

  template_vars = {
    namespace = local.namespace
    ports     = { for n, sv in var.services : n => sv.port }
  }

  # Scaling policy per service: the flavour sets the environment's shape, the catalog
  # overrides it where a service genuinely behaves differently. Resolved key by key
  # rather than with merge(), so a service can override one target without restating
  # the block — and so an omitted optional target stays omitted rather than becoming
  # null-versus-absent guesswork downstream.
  as_flavour = var.flavour.autoscaling

  autoscaling = {
    for name, svc in var.services : name => {
      enabled = try(svc.autoscaling.enabled, local.as_flavour.enabled)
      min     = try(svc.autoscaling.min, local.as_flavour.min, var.flavour.desired_count)
      # Relative, so a service that needs headroom gets it in proportion to the
      # environment rather than dragging a prod-sized ceiling into staging.
      max = ceil(
        try(local.as_flavour.max, var.flavour.desired_count * 3) *
        try(svc.autoscaling.max_factor, 1)
      )
      cpu_target         = try(svc.autoscaling.cpu_target, local.as_flavour.cpu_target, null)
      memory_target      = try(svc.autoscaling.memory_target, local.as_flavour.memory_target, null)
      request_target     = try(svc.autoscaling.request_target, local.as_flavour.request_target, null)
      scale_in_cooldown  = try(svc.autoscaling.scale_in_cooldown, local.as_flavour.scale_in_cooldown, 300)
      scale_out_cooldown = try(svc.autoscaling.scale_out_cooldown, local.as_flavour.scale_out_cooldown, 60)
      schedules          = try(svc.autoscaling.schedules, local.as_flavour.schedules, [])
    }
  }

  services = {
    for name, svc in var.services : name => merge(svc, {
      image = "${var.docker_registry}/${svc.image}:${var.image_tag}"
      size  = var.flavour.sizes[svc.size]
      ports = try(svc.ports, [svc.port])

      environment = concat(
        svc.runtime == "spring" ? local.common_spring_env : [],
        svc.runtime == "node" ? concat(local.node_env, [{ name = "OTEL_SERVICE_NAME", value = name }]) : [],
        svc.runtime == "caddy" ? local.caddy_env : [],
        try(svc.cdn, false) ? local.cdn_env : [],
        try(svc.database, false) ? local.database_env : [],
        # extra_env is rendered, not string-replaced: ${namespace} and ${ports.<svc>}
        # come from the catalog itself, so spg's merchant URL cannot drift from
        # merchant's declared port.
        [for k, v in try(svc.extra_env, {}) : { name = k, value = templatestring(v, local.template_vars) }],
      )

      secrets = try(svc.database, false) ? local.database_secret : []

      secret_arns = try(svc.database, false) ? [aws_db_instance.this.master_user_secret[0].secret_arn] : []

      # Only the services that actually touch a bucket get bucket permissions.
      s3_bucket_arns = compact([
        try(svc.cdn, false) ? aws_s3_bucket.cdn.arn : "",
        svc.runtime == "caddy" ? aws_s3_bucket.certs.arn : "",
      ])
    })
  }
}

# ------------------------------------------------------------------------- discovery

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = local.namespace
  description = "Service discovery for pod ${var.pod.name} in ${var.env}"
  vpc         = var.vpc_id
  tags        = var.tags
}

# --------------------------------------------------------------------------- cluster

resource "aws_ecs_cluster" "this" {
  name = "${local.prefix}-${local.layer}"

  setting {
    name  = "containerInsights"
    value = var.flavour.monitoring ? "enabled" : "disabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# -------------------------------------------------------------------------- services

module "service" {
  source = "../ecs-service"
  # Hibernating destroys every pod service. The cluster and namespace stay: both are
  # free, and keeping the namespace keeps its id stable across a wake.
  for_each = var.compute_enabled ? local.services : {}

  name    = each.key
  project = var.project
  env     = var.env
  layer   = local.layer

  cluster_name     = aws_ecs_cluster.this.name
  namespace_id     = aws_service_discovery_private_dns_namespace.this.id
  vpc_id           = var.vpc_id
  vpc_cidr_block   = var.vpc_cidr_block
  subnets          = var.task_subnet_ids
  assign_public_ip = var.assign_public_ip

  image       = each.value.image
  ports       = each.value.ports
  environment = each.value.environment
  secrets     = each.value.secrets

  cpu                        = each.value.size.cpu
  memory                     = each.value.size.memory
  desired_count              = var.flavour.desired_count
  autoscaling                = local.autoscaling[each.key]
  capacity                   = var.flavour.capacity
  health_check_grace_seconds = var.flavour.health_check_grace_seconds
  log_retention_days         = var.flavour.log_retention_days

  # spg attaches to both NLB listeners; everything else is internal to the pod.
  target_groups = try(each.value.edge.lb, "") == "nlb" ? {
    for port in each.value.edge.listeners : "tcp-${port}" => {
      arn  = aws_lb_target_group.spg[tostring(port)].arn
      port = port
    }
  } : {}

  secret_arns    = each.value.secret_arns
  s3_bucket_arns = each.value.s3_bucket_arns

  tags = merge(var.tags, { Service = each.key, Pod = var.pod.name })
}
