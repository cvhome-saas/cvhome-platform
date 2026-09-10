variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "pod" {
  description = "This pod's identity. `size` selects the flavour size table, so it is a real knob now."
  type = object({
    index  = number
    id     = string
    short  = string
    name   = string
    domain = string
  })
}

variable "services" {
  description = "The `pod` slice of services.yaml, passed through unchanged."
  type        = any
}

variable "flavour" {
  type = any
}

variable "domain" {
  type = string
}

variable "hosted_zone_id" {
  type = string
}

variable "cdn_certificate_arn" {
  description = "us-east-1 ACM certificate for the CDN's custom domain. Null serves the CloudFront default domain instead."
  type        = string
  default     = null
}

variable "core_namespace" {
  description = "The environment's core Cloud Map namespace, where the shared otel-collector lives."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr_block" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "task_subnet_ids" {
  type = list(string)
}

variable "assign_public_ip" {
  type = bool
}

variable "database_subnet_group_name" {
  type = string
}

variable "docker_registry" {
  type = string
}

variable "image_tag" {
  type = string
}

variable "test_stores" {
  type    = bool
  default = false
}

variable "compute_enabled" {
  description = <<-EOT
    When false the pod is hibernated: services and the network load balancer go, while
    the database, the media bucket, the CloudFront distribution and Caddy's certificate
    store stay. Keeping CloudFront matters — its domain is baked into media URLs
    already stored in the database, so recreating it would break them.
  EOT
  type        = bool
  default     = true
}

variable "postgres_version" {
  type = string
}

variable "database_shared" {
  description = <<-EOT
    Use store-core's database instead of creating one (flavour rds.shared, default pod
    only). Passed apart from shared_database because it keys a count, so it has to be
    known at plan time; shared_database's attributes do not exist until core's instance does.
  EOT
  type        = bool
  default     = false
}

variable "shared_database" {
  description = "store-core's database, when database_shared. Its services get ingress on its security group."
  type = object({
    identifier        = string
    address           = string
    port              = number
    db_name           = string
    username          = string
    secret_arn        = string
    security_group_id = string
  })
  default = null

  validation {
    condition     = !var.database_shared || var.shared_database != null
    error_message = "database_shared is true but no shared_database was passed."
  }
}

variable "tags" {
  description = "Extra identity tags. Project/Environment/Flavour arrive via provider default_tags."
  type        = map(string)
  default     = {}
}
