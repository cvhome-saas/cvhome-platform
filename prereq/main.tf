# Everything the image build and the environment apply depend on, and nothing else.
#
# This state exists because of a hard ordering constraint: ECR does not create a
# repository on push, so `gradlew bootBuildImage --publishImage` fails unless the
# repositories already exist — and the ALB listener cannot reference a certificate
# that has not been issued. Both must precede the build, which must precede the
# environment apply.
#
# Run order:  prereq apply  ->  image build  ->  env apply

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
      Repository  = "cvhome-platform"
      State       = "prereq"
    }
  }
}

data "aws_ssm_parameter" "config" {
  name = "/${var.project}/${var.env}/config"
}

locals {
  catalog = yamldecode(file("${path.module}/../services.yaml"))

  hosted_zone_id = coalesce(var.hosted_zone_id, jsondecode(data.aws_ssm_parameter.config.value).hosted_zone_id)

  # Every image the application build publishes, from the one catalog. The legacy
  # template listed 11 by hand and was missing six — which is why the build failed
  # before Terraform was ever reached.
  images = merge(
    { for name, svc in local.catalog.core : name => svc.image },
    { for name, svc in local.catalog.pod : name => svc.image },
  )
}

data "aws_route53_zone" "this" {
  zone_id = local.hosted_zone_id
}

# ----------------------------------------------------------------------------- ecr

resource "aws_ecr_repository" "this" {
  for_each = local.images

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "MUTABLE" # the deploy tag moves; digests are what pin a release

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Service = each.key }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last ${var.image_retention_count} untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ----------------------------------------------------------------------------- acm

resource "aws_acm_certificate" "this" {
  domain_name               = data.aws_route53_zone.this.name
  subject_alternative_names = ["*.${data.aws_route53_zone.this.name}"]
  validation_method         = "DNS"

  # The wildcard covers uaa, console-ui and every spg-<pod> storefront hostname.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for opt in aws_acm_certificate.this.domain_validation_options : opt.domain_name => opt
  }

  zone_id         = local.hosted_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
