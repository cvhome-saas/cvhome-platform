data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # <layer>-<service> keeps store-core-gateway distinct from a pod's gateway, and keeps
  # per-pod services distinct from each other (layer carries the pod id).
  qualified_name = "${var.layer}-${var.name}"
  prefix         = "${var.project}-${var.env}"

  # IAM role names cap at 64. The layer is redundant for core services (store-core-gateway
  # already says it) and for pod services the pod id is what disambiguates, so roles are
  # named from the pod id rather than the full layer. A precondition below refuses to
  # create a name that would be rejected, rather than letting the apply fail mid-flight.
  role_scope = var.layer == "store-core" ? "" : "${replace(var.layer, "store-pod-", "")}-"
  role_base  = "${local.prefix}-${local.role_scope}${var.name}"

  log_group = "/aws/ecs/${var.project}/${var.env}/${var.layer}/${var.name}"

  # One source of truth for how many tasks to start. With autoscaling on, the floor is
  # the autoscaling minimum, so the flavour cannot say 2 while the scaler says 1 and
  # each apply fights the scaler. Without it, the flavour's own count applies.
  desired = var.autoscaling.enabled ? var.autoscaling.min : var.desired_count

  scaling = var.autoscaling.enabled ? 1 : 0

  # Request-count tracking needs both suffixes to name the metric, so it is only
  # possible for a service behind an application load balancer.
  request_target_group = try([for tg in values(var.target_groups) : tg.arn_suffix if tg.arn_suffix != null][0], null)
  can_scale_on_requests = (
    var.autoscaling.request_target != null &&
    var.load_balancer_arn_suffix != null &&
    local.request_target_group != null
  )
}

# --------------------------------------------------------------------- security group

resource "aws_security_group" "this" {
  # Security group names allow 255 characters, so no truncation is needed here.
  name        = "${local.prefix}-${local.qualified_name}"
  description = "Ingress on ${var.name}'s own ports only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${local.prefix}-${local.qualified_name}" })

  lifecycle {
    create_before_destroy = true
  }
}

# One rule per port the container actually listens on. The legacy module opened
# 0-65535 for every service, so any compromised task could reach any other.
resource "aws_vpc_security_group_ingress_rule" "vpc" {
  for_each = toset([for p in var.ports : tostring(p)])

  security_group_id = aws_security_group.this.id
  description       = "In-VPC traffic to ${var.name}:${each.value}"
  cidr_ipv4         = var.vpc_cidr_block
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "load_balancer" {
  for_each = var.load_balancer_security_group_id == null ? toset([]) : toset([for p in var.ports : tostring(p)])

  security_group_id            = aws_security_group.this.id
  description                  = "Load balancer to ${var.name}:${each.value}"
  referenced_security_group_id = var.load_balancer_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Outbound: image pulls, AWS APIs, ACME, Stripe"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = var.tags
}

# ------------------------------------------------------------------------- logging

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---------------------------------------------------------------------- task defs

resource "aws_ecs_task_definition" "this" {
  family                   = "${local.prefix}-${local.qualified_name}"
  cpu                      = var.cpu
  memory                   = var.memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([
    {
      name        = var.name
      image       = var.image
      essential   = true
      environment = var.environment
      secrets     = var.secrets

      portMappings = [
        for p in var.ports : {
          name          = "${var.name}-${p}"
          containerPort = p
          hostPort      = p
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = var.tags
}

# ------------------------------------------------------------------------ discovery

# A records, not SRV: Caddy (spg) cannot consume SRV, and the application's
# ecs-service-discoveryclient resolves plain A records via DiscoverInstances.
resource "aws_service_discovery_service" "this" {
  name = var.name

  dns_config {
    namespace_id   = var.namespace_id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  tags = var.tags
}

# -------------------------------------------------------------------------- service

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_name
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = local.desired

  # Only meaningful when a load balancer is attached; harmless otherwise.
  health_check_grace_period_seconds = length(var.target_groups) > 0 ? var.health_check_grace_seconds : null

  network_configuration {
    subnets          = var.subnets
    assign_public_ip = var.assign_public_ip
    security_groups  = [aws_security_group.this.id]
  }

  service_registries {
    registry_arn   = aws_service_discovery_service.this.arn
    container_name = var.name
  }

  dynamic "load_balancer" {
    for_each = var.target_groups
    content {
      target_group_arn = load_balancer.value.arn
      container_name   = var.name
      container_port   = load_balancer.value.port
    }
  }

  # An on-demand base keeps the service alive through a Spot reclamation.
  dynamic "capacity_provider_strategy" {
    for_each = var.capacity.on_demand_base > 0 || var.capacity.on_demand_percent > 0 ? [1] : []
    content {
      capacity_provider = "FARGATE"
      base              = var.capacity.on_demand_base
      weight            = var.capacity.on_demand_percent
    }
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100 - var.capacity.on_demand_percent
  }

  deployment_controller {
    type = "ECS"
  }

  # A bad task definition rolls itself back instead of sitting in a crash loop.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = var.tags

  # No ignore_changes on desired_count. It was unconditional before, which meant a
  # change to the flavour's desired_count never took effect after first apply — prod
  # could not be raised from 2. Terraform now owns the baseline and the autoscaler
  # expands above it; an apply resets to baseline and the autoscaler re-expands within
  # a couple of minutes, which is the correct behaviour for a deploy.

  depends_on = [aws_iam_role_policy.execution]
}

# ----------------------------------------------------------------------- autoscaling
#
# Every policy below is optional and driven by config: the flavour sets the shape for
# an environment, the catalog overrides it for a service that behaves differently.
# Previously this was a fixed pair of CPU and memory policies with hardcoded targets,
# so "autoscaling" meant one thing everywhere it was switched on.

resource "aws_appautoscaling_target" "this" {
  count = local.scaling

  min_capacity       = var.autoscaling.min
  max_capacity       = var.autoscaling.max
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  tags = var.tags
}

resource "aws_appautoscaling_policy" "cpu" {
  count = local.scaling > 0 && var.autoscaling.cpu_target != null ? 1 : 0

  name               = "${local.role_base}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscaling.cpu_target
    scale_in_cooldown  = var.autoscaling.scale_in_cooldown
    scale_out_cooldown = var.autoscaling.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "memory" {
  count = local.scaling > 0 && var.autoscaling.memory_target != null ? 1 : 0

  name               = "${local.role_base}-mem"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = var.autoscaling.memory_target
    scale_in_cooldown  = var.autoscaling.scale_in_cooldown
    scale_out_cooldown = var.autoscaling.scale_out_cooldown
  }
}

# Requests per target per minute. This leads CPU for request-driven services: queueing
# shows up in request rate before it shows up in processor time.
resource "aws_appautoscaling_policy" "requests" {
  count = local.scaling > 0 && local.can_scale_on_requests ? 1 : 0

  name               = "${local.role_base}-req"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.load_balancer_arn_suffix}/${local.request_target_group}"
    }
    target_value       = var.autoscaling.request_target
    scale_in_cooldown  = var.autoscaling.scale_in_cooldown
    scale_out_cooldown = var.autoscaling.scale_out_cooldown
  }
}

# Known daily shape, rather than a reaction to load. A schedule sets the floor and
# ceiling; the target-tracking policies still move within them.
resource "aws_appautoscaling_scheduled_action" "this" {
  for_each = local.scaling > 0 ? { for sch in var.autoscaling.schedules : sch.name => sch } : {}

  name               = "${local.role_base}-${each.key}"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  schedule           = each.value.schedule
  timezone           = each.value.timezone

  scalable_target_action {
    min_capacity = each.value.min
    max_capacity = each.value.max
  }
}
