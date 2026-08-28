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
  dns_prefix = coalesce(var.dns_prefix, var.env == "prod" ? "" : var.env)
  app_domain = local.dns_prefix == "" ? data.aws_route53_zone.this.name : "${local.dns_prefix}.${data.aws_route53_zone.this.name}"
  image_tag  = coalesce(var.image_tag, try(local.ssm.image_tag, "latest"))
  pod_ids    = coalesce(var.pod_ids, try(local.ssm.pod_ids, []))

  # ------------------------------------------------------------------- the flavour
  #
  # One named bundle, with per-key overrides merged over it. `rds` and `capacity` are
  # merged one level deep so an override can change a single field without restating
  # the whole block.
  base = local.flavours[var.flavour]

  flavour = merge(local.base, var.flavour_overrides, {
    rds      = merge(local.base.rds, try(var.flavour_overrides.rds, {}))
    capacity = merge(local.base.capacity, try(var.flavour_overrides.capacity, {}))
    sizes    = merge(local.base.sizes, try(var.flavour_overrides.sizes, {}))
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
    precondition {
      condition     = local.prereq.app_domain == local.app_domain
      error_message = "The certificate in the prereq state covers '${local.prereq.app_domain}', but this environment serves '${local.app_domain}'. Re-apply prereq first."
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

  private_tasks   = local.flavour.private_tasks
  nat_gateway     = local.flavour.nat_gateway
  compute_enabled = !var.hibernated

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

  services       = local.catalog.core
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

  services = local.catalog.pod
  flavour  = local.flavour

  domain         = local.app_domain
  hosted_zone_id = local.hosted_zone_id
  core_namespace = module.store_core.namespace

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
}
