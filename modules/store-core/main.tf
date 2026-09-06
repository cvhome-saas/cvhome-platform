locals {
  layer     = "store-core"
  prefix    = "${var.project}-${var.env}"
  namespace = "store-core.${var.project}-${var.env}.lcl"

  profiles = join(",", compact(["fargate", var.test_stores ? "test-stores" : ""]))

  # The default pod's namespace, which core services use to reach pod services.
  default_pod = try(var.pods["pod-1"], null)

  # ---------------------------------------------------------------- env, computed once
  #
  # This block is the whole point of the catalog. The legacy store-core-cluster.tf
  # repeated ~25 of these lines inside each service definition, and store-pod-cluster.tf
  # repeated them six times over 654 lines. They are computed here exactly once and
  # merged with whatever a service genuinely needs on its own.

  otlp_endpoint = "http://otel-collector.${local.namespace}"

  # Only point at the collector when one is actually deployed. Previously the endpoint
  # was always set, so under dev every service retried exports to a service that did
  # not exist.
  otel_spring_env = var.flavour.monitoring ? [
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "${local.otlp_endpoint}:4318" },
    { name = "MANAGEMENT_OTLP_METRICS_EXPORT_URL", value = "${local.otlp_endpoint}:4318/v1/metrics" },
  ] : []

  otel_node_env = var.flavour.monitoring ? [
    { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "grpc" },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "${local.otlp_endpoint}:4317" },
  ] : []

  common_spring_env = [
    { name = "SPRING_PROFILES_ACTIVE", value = local.profiles },
    { name = "OTEL_SDK_DISABLED", value = tostring(!var.flavour.monitoring) },
    # OTEL_SDK_DISABLED only silences the OpenTelemetry SDK (traces, logs). Spring Boot's
    # spring-boot-starter-opentelemetry also ships Micrometer's OtlpMeterRegistry, which
    # has its own switch, defaults to enabled, and defaults its URL to
    # http://localhost:4318/v1/metrics. Under dev that produced a "Failed to publish
    # metrics to OTLP receiver ... Connection refused" warning every minute per task.
    { name = "MANAGEMENT_OTLP_METRICS_EXPORT_ENABLED", value = tostring(var.flavour.monitoring) },
    { name = "COM_ASREVO_CVHOME_APP_DOMAIN", value = var.domain },
    { name = "COM_ASREVO_CVHOME_APP_HANDLERS[0].schema", value = "https" },
    { name = "COM_ASREVO_CVHOME_APP_HANDLERS[0].port", value = "443" },
    { name = "SPRING_CLOUD_ECS_DISCOVERY_NAMESPACE", value = local.namespace },
    # Underscore, not the legacy "NAMESPACE-ID": a hyphen is not a valid POSIX
    # environment variable name, and this is the form Spring relaxed binding expects.
    { name = "SPRING_CLOUD_ECS_DISCOVERY_NAMESPACE_ID", value = aws_service_discovery_private_dns_namespace.this.id },
  ]

  # How each service addresses the ALB-fronted services, itself included: over TLS at
  # the edge on 443, whatever container port they actually listen on. Generated from
  # the catalog so a renamed service cannot leave a stale entry behind.
  #
  # A service's OWN entry is included on purpose, and SERVER_PORT below is what makes
  # that safe. common-config.yml derives server.port from
  # com.asrevo.cvhome.services.<own name>.port, so writing 443 there alone would tell
  # the service to bind a privileged port, which fails with EACCES under the non-root
  # buildpack user. An earlier version of this block excluded the service's own entry
  # for exactly that reason — and uaa then pinned its OAuth2 issuer to that entry
  # (ServiceDomainIssuerPin reads services.uaa), advertising http://uaa.<domain>:8001
  # while every resource server trusts https://uaa.<domain>. Every service-to-service
  # token was rejected with "Unsupported issuer" and a 401. The registry entry must be
  # the edge address for everyone, including the service it names; the bind port is
  # SERVER_PORT, which as an OS environment variable outranks server.port in any
  # config file.
  #
  # The hyphen is load-bearing and must NOT be converted to an underscore.
  # ServiceDomainProperties is Map<String, ServiceDomain>, so these names are map KEYS.
  # Spring builds a key from an environment variable by splitting on "_", so an
  # underscore becomes a nesting level:
  #
  #   ..._SERVICES_STORE-CORE-GATEWAY_SCHEMA -> services["store-core-gateway"].schema  OK
  #   ..._SERVICES_STORE_CORE_GATEWAY_SCHEMA -> services.store.core.gateway.schema     lost
  #
  # The wrong form binds nothing and reports no error: the service keeps the http/8000
  # defaults from common-config.yml and builds http:// URLs behind an https:// edge.
  edge_scheme_env = flatten([
    for peer, peer_svc in var.services : [
      { name = "COM_ASREVO_CVHOME_SERVICES_${upper(peer)}_SCHEMA", value = "https" },
      { name = "COM_ASREVO_CVHOME_SERVICES_${upper(peer)}_PORT", value = "443" },
    ] if try(peer_svc.edge.lb, "") == "alb"
  ])

  # The port a Spring service binds, stated explicitly so it no longer rides on the
  # service's own registry entry (see edge_scheme_env). Keyed by service.
  server_port_env = {
    for name, svc in var.services : name => [
      { name = "SERVER_PORT", value = tostring(svc.port) },
    ]
  }

  # spg lives in the pod layer but core services address it over the edge.
  spg_env = local.default_pod == null ? [] : [
    { name = "COM_ASREVO_CVHOME_SERVICES_SPG_SCHEMA", value = "https" },
    { name = "COM_ASREVO_CVHOME_SERVICES_SPG_PORT", value = "443" },
    { name = "COM_ASREVO_CVHOME_SERVICES_STORE_NAMESPACE", value = local.default_pod.namespace },
  ]

  pod_list_env = flatten([
    for key, pod in var.pods : [
      { name = "COM_ASREVO_CVHOME_PODS[${pod.index}]_ID", value = pod.id },
      { name = "COM_ASREVO_CVHOME_PODS[${pod.index}]_NAME", value = pod.name },
      { name = "COM_ASREVO_CVHOME_PODS[${pod.index}]_ENDPOINT_ENDPOINT", value = pod.endpoint },
      { name = "COM_ASREVO_CVHOME_PODS[${pod.index}]_ENDPOINT_TYPE", value = "EXTERNAL" },
    ]
  ])

  database_env = [
    { name = "SPRING_DATASOURCE_DATABASE", value = aws_db_instance.this.db_name },
    { name = "SPRING_DATASOURCE_HOST", value = aws_db_instance.this.address },
    { name = "SPRING_DATASOURCE_PORT", value = tostring(aws_db_instance.this.port) },
    { name = "SPRING_DATASOURCE_USERNAME", value = aws_db_instance.this.username },
    # Sized by the flavour to what the instance class can hold across every service in
    # the layer, with a rolling deploy's brief doubling included. Hikari's default of 10
    # exhausted a t4g.micro mid-deploy and tasks died on "remaining connection slots
    # are reserved" before they could pass a health check.
    { name = "SPRING_DATASOURCE_HIKARI_MAXIMUM-POOL-SIZE", value = tostring(var.flavour.rds.db_pool_size) },
  ]

  database_secret = [
    { name = "SPRING_DATASOURCE_PASSWORD", valueFrom = "${aws_db_instance.this.master_user_secret[0].secret_arn}:password::" },
  ]

  node_env = concat(
    [{ name = "OTEL_SDK_DISABLED", value = tostring(!var.flavour.monitoring) }],
    local.otel_node_env,
  )

  # Named secrets this layer can bind, as "<name>:<json-key>" in the catalog.
  secret_arns = {
    stripe = data.aws_secretsmanager_secret.stripe.arn
    uaa    = data.aws_secretsmanager_secret.uaa.arn
    sso    = data.aws_secretsmanager_secret.sso.arn
  }

  # Every Spring service in this layer authenticates to its peers as the store-core
  # service client, so its secret is bound here once rather than listed per service.
  # The environment variable is Spring's own name for
  # spring.security.oauth2.client.registration.s2s.client-secret, and as an OS
  # variable it outranks the value each application.yml ships with.
  # The layer's crypto key: what the secret-crypto provider wraps stored secrets with
  # (signing keys in uaa and cua, provider credentials in billing and payment). Bound
  # to every Spring service rather than to the ones known to encrypt today, because
  # the provider is on every classpath and falls back to a RANDOM key per boot when
  # none is configured: a service that starts encrypting quietly loses everything it
  # stored at its next restart. The provider type is pinned to ENV so the key wins
  # over any STATIC test key a profile ships with.
  crypto_secret = [
    {
      name      = "COM_ASREVO_CVHOME_CRYPTO_KEY"
      valueFrom = "${local.secret_arns.sso}:CORE_CRYPTO_KEY::"
    },
  ]

  crypto_env = [
    { name = "COM_ASREVO_CVHOME_CRYPTO_LOCAL_KEY-PROVIDER-TYPE", value = "ENV" },
  ]

  s2s_secret = [
    {
      name      = "SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_S2S_CLIENT_SECRET"
      valueFrom = "${local.secret_arns.sso}:UAA_STORE_CORE_SECRET::"
    },
  ]

  # uaa writes the client secrets and admin password it was given into its database
  # at boot only while this is on. A fresh environment needs it once; see the variable.
  uaa_seed_env = var.uaa_seed_on_boot ? [
    { name = "COM_ASREVO_CVHOME_UAA_SEED_APPLY-ON-BOOT", value = "true" },
  ] : []

  # ------------------------------------------------------------------ per-service wiring

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

      environment = concat(
        svc.runtime == "spring" ? concat(local.common_spring_env, local.otel_spring_env) : [],
        svc.runtime == "spring" ? concat(local.edge_scheme_env, local.server_port_env[name]) : [],
        svc.runtime == "spring" ? local.spg_env : [],
        svc.runtime == "spring" ? local.crypto_env : [],
        name == "uaa" ? local.uaa_seed_env : [],
        svc.runtime == "node" ? concat(local.node_env, [{ name = "OTEL_SERVICE_NAME", value = name }]) : [],
        try(svc.database, false) ? local.database_env : [],
        try(svc.needs_pod_list, false) ? local.pod_list_env : [],
        [for k, v in try(svc.extra_env, {}) : { name = k, value = v }],
      )

      secrets = concat(
        try(svc.database, false) ? local.database_secret : [],
        svc.runtime == "spring" ? concat(local.s2s_secret, local.crypto_secret) : [],
        [
          for env_name, ref in try(svc.secrets, {}) : {
            name      = env_name
            valueFrom = "${local.secret_arns[split(":", ref)[0]]}:${split(":", ref)[1]}::"
          }
        ],
      )

      secret_arns = distinct(compact(concat(
        try(svc.database, false) ? [aws_db_instance.this.master_user_secret[0].secret_arn] : [],
        svc.runtime == "spring" ? [local.secret_arns.sso] : [],
        [for ref in values(try(svc.secrets, {})) : local.secret_arns[split(":", ref)[0]]],
      )))
    })
  }
}

# ------------------------------------------------------------------------- discovery

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = local.namespace
  description = "Service discovery for ${local.layer} in ${var.env}"
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

# -------------------------------------------------------------------------- secrets

# Created by the bootstrap stack, which owns the values a human supplied.
data "aws_secretsmanager_secret" "stripe" {
  name = "/${var.project}/${var.env}/stripe"
}

data "aws_secretsmanager_secret" "uaa" {
  name = "/${var.project}/${var.env}/uaa"
}

# Generated by the bootstrap stack: uaa's client secrets, both remember-me keys and
# both crypto keys. Nobody ever typed these.
data "aws_secretsmanager_secret" "sso" {
  name = "/${var.project}/${var.env}/sso"
}

# -------------------------------------------------------------------------- services

module "service" {
  source = "../ecs-service"
  # Hibernating destroys every service; the cluster and namespace stay because they
  # cost nothing and keep the namespace id stable across a wake.
  for_each = { for name, svc in local.services : name => svc if var.compute_enabled }

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
  ports       = [each.value.port]
  environment = each.value.environment
  secrets     = each.value.secrets

  cpu                        = each.value.size.cpu
  memory                     = each.value.size.memory
  desired_count              = var.flavour.desired_count
  autoscaling                = local.autoscaling[each.key]
  capacity                   = var.flavour.capacity
  health_check_grace_seconds = var.flavour.health_check_grace_seconds
  log_retention_days         = var.flavour.log_retention_days

  target_groups = try(each.value.edge.lb, "") == "alb" ? {
    alb = {
      arn        = aws_lb_target_group.service[each.key].arn
      port       = each.value.port
      arn_suffix = aws_lb_target_group.service[each.key].arn_suffix
    }
  } : {}

  # Only ALB-fronted services can scale on request count; the metric is named by the
  # load balancer and target group together.
  load_balancer_arn_suffix = try(each.value.edge.lb, "") == "alb" ? aws_lb.this[0].arn_suffix : null

  load_balancer_attached          = try(each.value.edge.lb, "") == "alb"
  load_balancer_security_group_id = try(each.value.edge.lb, "") == "alb" ? aws_security_group.alb[0].id : null

  secret_arns = each.value.secret_arns

  tags = merge(var.tags, { Service = each.key })
}

# One collector for the whole environment. The legacy stack ran one here and another in
# every pod — N+1 for N pods. Pod tasks resolve this one across the namespace boundary,
# because Cloud Map namespaces are private hosted zones in the same VPC.
module "otel_collector" {
  source = "../ecs-service"
  count  = var.compute_enabled && var.flavour.monitoring ? 1 : 0

  name    = "otel-collector"
  project = var.project
  env     = var.env
  layer   = local.layer

  cluster_name     = aws_ecs_cluster.this.name
  namespace_id     = aws_service_discovery_private_dns_namespace.this.id
  vpc_id           = var.vpc_id
  vpc_cidr_block   = var.vpc_cidr_block
  subnets          = var.task_subnet_ids
  assign_public_ip = var.assign_public_ip

  image = var.otel_collector.image
  ports = var.otel_collector.ports

  environment = [
    { name = "AWS_REGION", value = var.region },
  ]

  cpu                        = var.flavour.sizes[var.otel_collector.size].cpu
  memory                     = var.flavour.sizes[var.otel_collector.size].memory
  desired_count              = 1
  autoscaling                = { enabled = false }
  capacity                   = var.flavour.capacity
  health_check_grace_seconds = var.flavour.health_check_grace_seconds
  log_retention_days         = var.flavour.log_retention_days

  tags = merge(var.tags, { Service = "otel-collector" })
}
