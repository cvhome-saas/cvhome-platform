# Two buckets per pod, with different jobs and very different access.
#
#   cdn    public-read *through CloudFront only*, written by the services the catalog
#          marks cdn:true. Holds tenant media.
#   certs  private, written and read by spg alone. Holds the on-demand TLS certificates
#          Caddy mints for custom tenant domains — losing it means re-issuing every one.

resource "aws_s3_bucket" "cdn" {
  bucket_prefix = substr("${local.prefix}-${var.pod.short}-cdn-", 0, 37)

  # Media is reproducible from the source of record; a pod teardown should not wedge.
  force_destroy = !var.flavour.protected

  tags = merge(var.tags, { Name = "${local.layer}-cdn" })
}

resource "aws_s3_bucket_public_access_block" "cdn" {
  bucket = aws_s3_bucket.cdn.id

  block_public_acls       = true
  block_public_policy     = false # the CloudFront OAC policy below is not "public"
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cdn" {
  bucket = aws_s3_bucket.cdn.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket" "certs" {
  bucket_prefix = substr("${local.prefix}-${var.pod.short}-certs-", 0, 37)

  # Never force-destroy under a protected flavour: these are real certificates, and
  # losing them means re-issuing one per custom tenant domain.
  force_destroy = !var.flavour.protected

  tags = merge(var.tags, { Name = "${local.layer}-certs" })
}

resource "aws_s3_bucket_public_access_block" "certs" {
  bucket = aws_s3_bucket.certs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "certs" {
  bucket = aws_s3_bucket.certs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "certs" {
  bucket = aws_s3_bucket.certs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ------------------------------------------------------------------------ cloudfront

# Origin access control, not the legacy origin access identity: OAI is superseded and
# does not support SigV4 against SSE-KMS origins.
resource "aws_cloudfront_origin_access_control" "cdn" {
  name                              = "${local.prefix}-${var.pod.short}-cdn"
  description                       = "CloudFront to the ${var.pod.name} media bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.prefix} ${var.pod.name} media"
  http_version    = "http2and3"

  # From the flavour directly. This used to key off flavour.monitoring, so enabling
  # monitoring in staging silently tripled the CDN's edge footprint.
  price_class = var.flavour.cdn_price_class

  origin {
    origin_id                = "cdn"
    domain_name              = aws_s3_bucket.cdn.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.cdn.id
  }

  default_cache_behavior {
    target_origin_id       = "cdn"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed policies: CachingOptimized, and CORS-with-preflight response headers.
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = "5cc3b908-e619-4b99-88e5-2cf7f45965bd"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = var.tags
}

data "aws_iam_policy_document" "cdn" {
  statement {
    sid       = "CloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.cdn.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # Only this distribution, not every CloudFront distribution in the world.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "cdn" {
  bucket = aws_s3_bucket.cdn.id
  policy = data.aws_iam_policy_document.cdn.json

  depends_on = [aws_s3_bucket_public_access_block.cdn]
}

# Only two things under the storefront prefix grow without bound: the hashed output in
# _next/static, which gets new filenames every build, and one marker per build. Files
# from public/ are not hashed, so every build overwrites the same keys and they need no
# rule at all. Tenant media lives outside this prefix and is never touched here.
#
# The two windows are deliberately different, and the order is the whole point.
# sync-s3.mjs writes the marker last, after every asset, so it is the newest object of a
# build. Under one uniform rule the assets would expire first and leave the marker
# standing, and a task booting into that gap finds the marker, skips the upload, and
# serves 404s for the rest of its life. Expiring the marker first makes the only
# reachable failure the harmless one: no marker, so the next boot re-uploads.
#
# The residual risk is a task that outlives the asset window, because a running task
# never re-syncs. That is what static_asset_retention_days is for: it should exceed the
# longest task lifetime the environment realistically sees.
resource "aws_s3_bucket_lifecycle_configuration" "cdn" {
  bucket = aws_s3_bucket.cdn.id

  rule {
    id     = "storefront-build-markers"
    status = "Enabled"

    filter {
      prefix = "${local.static_assets_prefix}/_builds/"
    }

    expiration {
      days = var.flavour.static_asset_retention_days
    }
  }

  rule {
    id     = "storefront-static-output"
    status = "Enabled"

    filter {
      prefix = "${local.static_assets_prefix}/_next/"
    }

    expiration {
      days = var.flavour.static_asset_retention_days + local.static_assets_grace_days
    }
  }

  # Parts of a failed multipart upload are invisible in the console and billed until
  # they are aborted. Applies to the whole bucket, tenant media included.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
