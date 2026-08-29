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

variable "tags" {
  description = "Extra identity tags. Project/Environment/Flavour arrive via provider default_tags."
  type        = map(string)
  default     = {}
}
