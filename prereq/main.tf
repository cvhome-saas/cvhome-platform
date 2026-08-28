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

  # Environments must not share hostnames. Below prod every host sits under an
  # env-scoped label, so dev and prod can share one hosted zone without fighting over
  # the same Route53 records. prod owns the bare apex.
  dns_prefix = coalesce(var.dns_prefix, var.env == "prod" ? "" : var.env)

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

locals {
  # The apex this environment actually serves, and the wildcard covering every host
  # under it: uaa, console-ui and each spg-<pod> storefront.
  app_domain = local.dns_prefix == "" ? data.aws_route53_zone.this.name : "${local.dns_prefix}.${data.aws_route53_zone.this.name}"
}

resource "aws_acm_certificate" "this" {
  domain_name               = local.app_domain
  subject_alternative_names = ["*.${local.app_domain}"]
  validation_method         = "DNS"

  # The wildcard covers uaa, console-ui and every spg-<pod> storefront hostname.
  lifecycle {
    create_before_destroy = true
  }
}

# Keyed by record NAME, not by domain name. The apex and the wildcard emit the same
# validation CNAME, so keying by domain_name created two Terraform resources managing
# one DNS record — masked by allow_overwrite until it surfaced as an apply conflict.
resource "aws_route53_record" "validation" {
  for_each = {
    for opt in aws_acm_certificate.this.domain_validation_options :
    opt.resource_record_name => opt...
  }

  zone_id         = local.hosted_zone_id
  name            = each.key
  type            = each.value[0].resource_record_type
  records         = distinct([for o in each.value : o.resource_record_value])
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# The env root reads the ARN from here rather than looking a certificate up by domain.
# A data-source lookup with most_recent = true would happily select any other issued
# certificate for the same domain in the account.
resource "aws_ssm_parameter" "outputs" {
  name        = "/${var.project}/${var.env}/prereq"
  type        = "String"
  description = "Outputs of the prereq state, consumed by the environment apply"

  value = jsonencode({
    certificate_arn = aws_acm_certificate_validation.this.certificate_arn
    app_domain      = local.app_domain
    dns_prefix      = local.dns_prefix
    registry        = split("/", values(aws_ecr_repository.this)[0].repository_url)[0]
  })
}
