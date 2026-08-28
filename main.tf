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

# Created in the prereq state, alongside the ECR repositories, because the certificate
# must exist and be validated before the ALB listener can reference it.
data "aws_acm_certificate" "this" {
  domain      = data.aws_route53_zone.this.name
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  catalog  = yamldecode(file("${path.module}/services.yaml"))
  flavours = yamldecode(file("${path.module}/flavours.yaml"))

  # -------------------------------------------------------------- config layering
  #
  # SSM holds what the bootstrap generated; tfvars holds what a human chose; tfvars
  # wins. Someone who never touches git still gets a working environment, and a team
  # that does gets reviewable diffs.
  ssm = jsondecode(data.aws_ssm_parameter.config.value)

  hosted_zone_id = coalesce(var.hosted_zone_id, local.ssm.hosted_zone_id)
  image_tag      = coalesce(var.image_tag, try(local.ssm.image_tag, "latest"))
  pod_ids        = coalesce(var.pod_ids, try(local.ssm.pod_ids, []))

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
  # Pod 1 is the default pod every environment has; the rest come from pod_ids.
  # `short` is the 8-character prefix the application already uses in hostnames
  # and namespace names.
  all_pod_ids = concat(["507f1f77bcf86cd799439011"], local.pod_ids)

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
      index    = pod.index
      id       = pod.id
      name     = pod.name
      endpoint = "https://${pod.domain}.${data.aws_route53_zone.this.name}"
      domain   = "store-pod-${pod.short}.${var.project}-${var.env}.lcl"
    }
  }

  docker_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${var.project}"

  tags = {}
}

# ------------------------------------------------------------------------- network

module "network" {
  source = "./modules/network"

  project    = var.project
  env        = var.env
  cidr_block = var.vpc_cidr_block
  az_count   = var.az_count

  private_tasks = local.flavour.private_tasks
  nat_gateway   = local.flavour.nat_gateway

  tags = local.tags
}

# --------------------------------------------------------------------------- logs

resource "aws_s3_bucket" "logs" {
  bucket_prefix = "${var.project}-${var.env}-logs-"
  force_destroy = !local.flavour.rds.deletion_protection

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

  # NLB access logs come from the delivery service principal instead.
  statement {
    sid       = "NlbAccessLogs"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "NlbAccessLogsAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
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

  domain          = data.aws_route53_zone.this.name
  hosted_zone_id  = local.hosted_zone_id
  certificate_arn = data.aws_acm_certificate.this.arn

  vpc_id                     = module.network.vpc_id
  vpc_cidr_block             = module.network.cidr_block
  public_subnet_ids          = module.network.public_subnet_ids
  task_subnet_ids            = module.network.task_subnet_ids
  assign_public_ip           = module.network.assign_public_ip
  database_subnet_group_name = module.network.database_subnet_group_name

  log_bucket_id   = aws_s3_bucket.logs.id
  docker_registry = local.docker_registry
  image_tag       = local.image_tag

  pods        = local.pod_summaries
  test_stores = var.test_stores

  tags = local.tags
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

  domain         = data.aws_route53_zone.this.name
  hosted_zone_id = local.hosted_zone_id
  core_namespace = module.store_core.namespace

  vpc_id                     = module.network.vpc_id
  vpc_cidr_block             = module.network.cidr_block
  public_subnet_ids          = module.network.public_subnet_ids
  task_subnet_ids            = module.network.task_subnet_ids
  assign_public_ip           = module.network.assign_public_ip
  database_subnet_group_name = module.network.database_subnet_group_name

  log_bucket_id   = aws_s3_bucket.logs.id
  docker_registry = local.docker_registry
  image_tag       = local.image_tag

  test_stores = var.test_stores

  tags = local.tags
}
