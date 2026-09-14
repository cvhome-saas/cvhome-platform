provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      Flavour     = var.flavour
      ManagedBy   = "terraform"
      Repository  = "cvhome-platform"
    }
  }
}

data "aws_caller_identity" "current" {}

# The record the bootstrap stack wrote. It holds what a human chose in the console,
# plus what CloudFormation generated (pod ids, the zone). Terraform reads it rather
# than re-deriving any of it.
data "aws_ssm_parameter" "config" {
  name = "/${var.project}/${var.env}/config"
}

data "aws_route53_zone" "this" {
  zone_id = local.hosted_zone_id
}

# Published by the prereq state. Read explicitly rather than looked up by domain: a
# data-source lookup with most_recent = true selects any issued certificate for the
# domain in the account, including one this stack does not own.
data "aws_ssm_parameter" "prereq" {
  name = "/${var.project}/${var.env}/prereq"
}

locals {
  catalog  = yamldecode(file("${path.module}/services.yaml"))
  flavours = yamldecode(file("${path.module}/flavours.yaml"))

  # -------------------------------------------------------------- config layering
  #
  # SSM holds what the bootstrap generated; tfvars holds what a human chose; tfvars
  # wins. Someone who never touches git still gets a working environment, and a team
  # that does gets reviewable diffs.
  # nonsensitive: the provider marks a data.aws_ssm_parameter value sensitive whatever
  # the parameter type is, and sensitivity is contagious. pod_ids flows into local.pods,
  # which is a for_each key, and a for_each key may not be sensitive because it would
  # surface in resource addresses. Both of these are String parameters holding the
  # non-secret configuration the bootstrap stack generated. Real secrets stay in Secrets
  # Manager and reach tasks by ARN, so nothing unwrapped here was ever secret.
  ssm    = jsondecode(nonsensitive(data.aws_ssm_parameter.config.value))
  prereq = jsondecode(nonsensitive(data.aws_ssm_parameter.prereq.value))

  hosted_zone_id = coalesce(var.hosted_zone_id, local.ssm.hosted_zone_id)

  # Every hostname sits under an env-scoped label below prod, so two environments can
  # share a hosted zone. Previously the apex, www, uaa, console-ui and every pod record
  # were env-independent, so dev and prod fought over identical Route53 records and the
  # last apply won. Derived the same way in the prereq root, which mints the matching
  # certificate; the value it used is echoed back here as a cross-check.
  #
  # Not coalesce(): it skips empty strings as well as nulls, so prod's "" was never
  # returned and every prod plan failed with "no non-null, non-empty-string arguments",
  # and an explicit dns_prefix = "" was silently replaced by the environment name.
  dns_prefix = var.dns_prefix != null ? var.dns_prefix : (var.env == "prod" ? "" : var.env)
  app_domain = local.dns_prefix == "" ? data.aws_route53_zone.this.name : "${local.dns_prefix}.${data.aws_route53_zone.this.name}"
  # No "latest" fallback: an environment deploys the product version named in its
  # tfvars (or, before the first promotion PR, the one the bootstrap wrote to SSM).
  # A missing value is an error rather than a silent moving target.
  image_tag = coalesce(var.image_tag, try(local.ssm.image_tag, null))
  pod_ids   = coalesce(var.pod_ids, try(local.ssm.pod_ids, []))

  # ------------------------------------------------------------------- the flavour
  #
  # One named bundle, with per-key overrides merged over it. `rds`, `capacity`, `sizes`
  # and `network` are merged one level deep so an override can change a single field
  # without restating the whole block.
  base = local.flavours[var.flavour]

  flavour = merge(local.base, var.flavour_overrides, {
    rds      = merge(local.base.rds, try(var.flavour_overrides.rds, {}))
    capacity = merge(local.base.capacity, try(var.flavour_overrides.capacity, {}))
    sizes    = merge(local.base.sizes, try(var.flavour_overrides.sizes, {}))
    network  = merge(local.base.network, try(var.flavour_overrides.network, {}))
  })

  # ----------------------------------------------------------------------- pods
  #
  # Every environment has one pod without being asked. Its id is fixed rather than
  # generated so that a rebuilt environment keeps the same storefront hostname and
  # Cloud Map namespace; the application's own local profile uses the same value.
  default_pod_id = "507f1f77bcf86cd799439011"

  # `short` is the 8-character prefix the application already uses in hostnames and
  # namespace names, so it must be unique across pods — see the precondition below.
  all_pod_ids = concat([local.default_pod_id], local.pod_ids)

  pods = {
    for i, id in local.all_pod_ids : "pod-${i + 1}" => {
      index  = i
      id     = id
      short  = substr(id, 0, 8)
      name   = "pod-${substr(id, 0, 8)}"
      domain = "spg-${substr(id, 0, 8)}"
    }
  }

  # What store-core needs to know about each pod.
  pod_summaries = {
    for key, pod in local.pods : key => {
      index     = pod.index
      id        = pod.id
      name      = pod.name
      endpoint  = "https://${pod.domain}.${local.app_domain}"
      namespace = "store-pod-${pod.short}.${var.project}-${var.env}.lcl"
    }
  }

  docker_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${var.project}"

  # ------------------------------------------------------------ per-service values
  #
  # What a service takes from the flavour unless its catalog entry says otherwise,
  # resolved once here and handed to the layer modules on the catalog entry itself. The
  # connection budget below counts exactly the numbers the modules deploy, so both read
  # them from this one place rather than each deriving its own.
  #
  #   db_pool_size  Hikari's pool per task: the service's own, else rds.db_pool_size.
  #                 Zero for a service with no database, so a sum needs no filter.
  #   scaling       the service's scaling policy: the flavour sets the environment's
  #                 shape, the catalog overrides it where a service genuinely behaves
  #                 differently. Resolved key by key rather than with merge(), so a service
  #                 can override one target without restating the block, and an omitted
  #                 optional target stays omitted rather than becoming null-versus-absent
  #                 guesswork downstream.
  #
  # A service's ceiling is relative, so one that needs headroom gets it in proportion to
  # the environment rather than dragging a prod-sized ceiling into staging: max_factor
  # times the flavour's max. A service with a database scales from a lower base, the
  # smaller of that max and rds.db_max_tasks, because every task it adds opens another
  # pool on an instance whose connections do not grow. A base below the floor is the
  # floor.
  as_flavour = local.flavour.autoscaling

  # Which services open a database connection at all, by layer.
  database = {
    for layer in ["core", "pod"] : layer => {
      for name, svc in local.catalog[layer] : name => try(svc.database, false)
    }
  }

  scaling = {
    for layer in ["core", "pod"] : layer => {
      for name, svc in local.catalog[layer] : name => {
        enabled = try(svc.autoscaling.enabled, local.as_flavour.enabled)
        min     = try(svc.autoscaling.min, local.as_flavour.min, local.flavour.desired_count)
        max = ceil(
          (local.database[layer][name] ? max(
            try(svc.autoscaling.min, local.as_flavour.min, local.flavour.desired_count),
            min(try(local.as_flavour.max, local.flavour.desired_count * 3), local.flavour.rds.db_max_tasks),
          ) : try(local.as_flavour.max, local.flavour.desired_count * 3)) * try(svc.autoscaling.max_factor, 1)
        )
        cpu_target         = try(svc.autoscaling.cpu_target, local.as_flavour.cpu_target, null)
        memory_target      = try(svc.autoscaling.memory_target, local.as_flavour.memory_target, null)
        request_target     = try(svc.autoscaling.request_target, local.as_flavour.request_target, null)
        scale_in_cooldown  = try(svc.autoscaling.scale_in_cooldown, local.as_flavour.scale_in_cooldown, 300)
        scale_out_cooldown = try(svc.autoscaling.scale_out_cooldown, local.as_flavour.scale_out_cooldown, 60)
        schedules          = try(svc.autoscaling.schedules, local.as_flavour.schedules, [])
      }
    }
  }

  # A schedule sets the same min and max on every service, so each is clamped to the
  # service it lands on: never past the service's own ceiling, and never above a database
  # service's floor. The calendar may lower a database service (to zero overnight, say)
  # but not raise it, since the budget below counts every database task at its floor or
  # its ceiling and a schedule's numbers are neither. A schedule without a max leaves
  # every service its own ceiling, which is what raising a floor for an event wants.
  services = {
    for layer, scaled in local.scaling : layer => {
      for name, sc in scaled : name => merge(local.catalog[layer][name], {
        db_pool_size = local.database[layer][name] ? try(local.catalog[layer][name].db_pool_size, local.flavour.rds.db_pool_size) : 0
        scaling = merge(sc, {
          schedules = [
            for sch in sc.schedules : merge(sch, {
              min = min(sch.min, local.database[layer][name] ? sc.min : sc.max)
              max = min(coalesce(try(sch.max, null), sc.max), sc.max)
            })
          ]
        })
      })
    }
  }

  # ------------------------------------------------------------ database connections
  #
  # Every Spring service with a database holds up to its db_pool_size connections per
  # task. Where the default pod shares store-core's instance, both layers' pools land on
  # it. A service's task count peaks one of two ways, and the budget takes the larger:
  #
  #   at its ceiling   autoscaling has added every task it may (scaling.max);
  #   mid-deploy       a rolling deploy runs the old and the new tasks side by side, at
  #                    the floor, since an apply resets desired_count to the floor
  #                    (modules/ecs-service) and ECS then starts up to twice that.
  #
  # Where scaling is off, both are desired_count, and the peak is the deploy's doubling.
  # A deploy forced by hand while a service sits at its ceiling can briefly open more;
  # cvhome's three-second Hikari timeout turns that into quick errors, not a stall.
  #
  # With the flavours as written (pool x peak tasks, per instance):
  #   dev, ephemeral  one shared db.t4g.micro, scaling off: every service at 1 task,
  #                   2 mid-deploy. (ten services x 3 + catalog 8) x 2 = 76 of ~80.
  #   staging         floor 1, database ceiling 2, catalog 4. Pod instance: catalog
  #                   8 x 4 + six services x 6 x 2 = 104; core: four x 6 x 2 = 48. Of ~190.
  #   prod            floor 2, database ceiling 2, catalog 4. Pod instance: catalog
  #                   8 x max(4, 2x2) + six services x 6 x max(2, 2x2) = 32 + 144 = 176;
  #                   core: four x 6 x 4 = 96. Of ~190. Before the ceiling, every service
  #                   scaled to 12 tasks: 7 x 6 x 12 = 504 on one pod's instance.
  shared_database = local.flavour.rds.shared

  # What RDS for PostgreSQL allows, rounded down: LEAST(DBInstanceClassMemory/9531392,
  # 5000), where DBInstanceClassMemory is what is left after RDS takes its own share.
  # Hence about 80 on a t4g.micro, not the 110 the nominal gigabyte suggests.
  db_connection_limits = {
    "db.t4g.micro"  = 80
    "db.t4g.small"  = 190
    "db.t4g.medium" = 400
  }

  # Every database service in a layer at its peak task count, pools summed.
  db_connections = {
    for layer, services in local.services : layer => sum(concat([0], [
      for svc in values(services) : svc.db_pool_size * max(
        svc.scaling.enabled ? svc.scaling.max : local.flavour.desired_count,
        2 * (svc.scaling.enabled ? svc.scaling.min : local.flavour.desired_count),
      )
    ]))
  }

  # The busiest instance.
  db_connections_peak = local.shared_database ? local.db_connections.core + local.db_connections.pod : max(local.db_connections.core, local.db_connections.pod)
  db_connection_limit = lookup(local.db_connection_limits, local.flavour.rds.instance_class, null)
}

# B2/B3: fail at plan time, with a sentence, rather than mid-apply with an AWS error.
resource "terraform_data" "guards" {
  lifecycle {
    precondition {
      condition     = length(distinct([for p in local.pods : p.short])) == length(local.pods)
      error_message = "Two pods share the first 8 characters of their id, which is what names the Cloud Map namespace, load balancer, database and DNS record. Regenerate pod_ids with fully random values."
    }
    precondition {
      condition     = length(var.project) + length(var.env) <= 34
      error_message = "project + env is ${length(var.project) + length(var.env)} characters. Names built from both must fit AWS limits — keep the total at 34 or below."
    }
    # Load balancers under a protected flavour have deletion protection on, and
    # Terraform cannot disable it and delete in one apply — the destroy simply fails.
    # More to the point, an environment worth protecting is not one to hibernate.
    precondition {
      condition     = !(var.hibernated && local.flavour.protected)
      error_message = "Flavour '${var.flavour}' is protected, so this environment cannot be hibernated. Hibernation is for dev, staging and ephemeral environments."
    }
    # A protected environment runs a released product version, never whatever the
    # last branch build pushed. Promotion is a PR changing envs/<env>.tfvars image_tag
    # (docs/release-plan.md in cvhome-saas/orchestrator). Not a variable validation:
    # dev and staging legitimately run `latest` until the first tagged release.
    precondition {
      condition     = !(local.flavour.protected && local.image_tag == "latest")
      error_message = "Flavour '${var.flavour}' is protected, so image_tag must be a released product version (X.Y.Z), not 'latest'. Set image_tag in envs/${var.env}.tfvars."
    }
    precondition {
      condition     = local.prereq.app_domain == local.app_domain
      error_message = "The certificate in the prereq state covers '${local.prereq.app_domain}', but this environment serves '${local.app_domain}'. Re-apply prereq first."
    }
    # Hikari's default pool of 10 once exhausted a t4g.micro mid-deploy, and tasks died
    # on "remaining connection slots are reserved" before passing a health check. One
    # instance serving two layers makes that easier to reach, and so does scaling out,
    # since pools multiply by tasks and an instance's connections do not; both are
    # counted here. Classes missing from db_connection_limits are not checked.
    precondition {
      condition     = local.db_connection_limit == null || local.db_connections_peak <= coalesce(local.db_connection_limit, 0)
      error_message = "At their ceilings, or mid-deploy at their floors, the database services would open ${local.db_connections_peak} connections on one ${local.flavour.rds.instance_class}, which holds about ${coalesce(local.db_connection_limit, 0)}. Lower rds.db_pool_size (or a service's db_pool_size in services.yaml) or rds.db_max_tasks, or raise rds.instance_class in flavour_overrides."
    }
  }
}

# ------------------------------------------------------------------------- network

module "network" {
  source = "./modules/network"

  project    = var.project
  env        = var.env
  cidr_block = var.vpc_cidr_block
  az_count   = var.az_count

  egress            = local.flavour.network.egress
  nat_instance_type = local.flavour.network.nat_instance_type
  compute_enabled   = !var.hibernated
}

# --------------------------------------------------------------------------- logs

resource "aws_s3_bucket" "logs" {
  bucket_prefix = "${var.project}-${var.env}-logs-"
  force_destroy = !local.flavour.protected

  tags = { Name = "${var.project}-${var.env}-logs" }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = local.flavour.log_retention_days
    }
  }
}

data "aws_elb_service_account" "current" {}

data "aws_iam_policy_document" "logs" {
  # Classic/ALB access logs are delivered by a per-region service account principal.
  statement {
    sid       = "AlbAccessLogs"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.current.arn]
    }
  }

}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# ----------------------------------------------------------------------- store-core

module "store_core" {
  source = "./modules/store-core"

  project = var.project
  env     = var.env
  region  = var.region

  services       = local.services.core
  otel_collector = local.catalog.infra["otel-collector"]
  flavour        = local.flavour

  domain          = local.app_domain
  hosted_zone_id  = local.hosted_zone_id
  certificate_arn = local.prereq.certificate_arn

  vpc_id                     = module.network.vpc_id
  vpc_cidr_block             = module.network.cidr_block
  public_subnet_ids          = module.network.public_subnet_ids
  task_subnet_ids            = module.network.task_subnet_ids
  assign_public_ip           = module.network.assign_public_ip
  database_subnet_group_name = module.network.database_subnet_group_name

  log_bucket_id   = aws_s3_bucket.logs.id
  docker_registry = local.docker_registry
  image_tag       = local.image_tag

  pods             = local.pod_summaries
  test_stores      = var.test_stores
  uaa_seed_on_boot = var.uaa_seed_on_boot
  postgres_version = var.postgres_version
  compute_enabled  = !var.hibernated
}

# ------------------------------------------------------------------------ store-pod

module "store_pod" {
  source   = "./modules/store-pod"
  for_each = local.pods

  project = var.project
  env     = var.env
  pod     = each.value

  services = local.services.pod
  flavour  = local.flavour

  domain         = local.app_domain
  hosted_zone_id = local.hosted_zone_id
  core_namespace = module.store_core.namespace

  # try: a prereq state written before the edge certificate existed has no such key,
  # and the pod falls back to the CloudFront default domain rather than failing the
  # apply. Re-running prereq fills it in.
  cdn_certificate_arn = try(local.prereq.cdn_certificate_arn, null)

  vpc_id                     = module.network.vpc_id
  vpc_cidr_block             = module.network.cidr_block
  public_subnet_ids          = module.network.public_subnet_ids
  task_subnet_ids            = module.network.task_subnet_ids
  assign_public_ip           = module.network.assign_public_ip
  database_subnet_group_name = module.network.database_subnet_group_name

  # No log_bucket_id: a network load balancer only writes access logs for TLS
  # listeners, and these are TCP passthrough so Caddy can terminate TLS itself.
  docker_registry = local.docker_registry
  image_tag       = local.image_tag

  test_stores      = var.test_stores
  postgres_version = var.postgres_version
  compute_enabled  = !var.hibernated

  # Below prod the default pod uses store-core's database (flavour rds.shared). The
  # bool keys a count inside the module, so it travels apart from the object, whose
  # attributes are unknown until core's instance exists.
  database_shared = local.shared_database && each.value.index == 0
  shared_database = local.shared_database && each.value.index == 0 ? module.store_core.database : null
}

# ------------------------------------------------------------------------ dashboard

# One page per environment, from the metrics AWS publishes without being asked. It
# names the load balancers and services by their ARN suffixes, which do not exist while
# hibernated, so it goes and comes back with the rest of the hourly things.
module "dashboard" {
  source = "./modules/dashboard"
  count  = local.flavour.dashboard && !var.hibernated ? 1 : 0

  project = var.project
  env     = var.env
  region  = var.region

  core = {
    cluster_name              = module.store_core.cluster_name
    service_names             = module.store_core.service_names
    alb_arn_suffix            = module.store_core.alb_arn_suffix
    target_group_arn_suffixes = module.store_core.target_group_arn_suffixes
    db_identifier             = module.store_core.db_identifier
    log_group_names           = module.store_core.log_group_names
  }

  pods = {
    for key, pod in module.store_pod : key => {
      name                          = local.pods[key].name
      cluster_name                  = pod.cluster_name
      service_names                 = pod.service_names
      nlb_arn_suffix                = pod.nlb_arn_suffix
      nlb_target_group_arn_suffixes = pod.nlb_target_group_arn_suffixes
      db_identifier                 = pod.db_identifier
      cdn_distribution_id           = pod.cdn_distribution_id
      log_group_names               = pod.log_group_names
    }
  }

  nat_gateway_id  = module.network.nat_gateway_id
  nat_instance_id = module.network.nat_instance_id
}
