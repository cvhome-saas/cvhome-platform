variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type = string
}

variable "services" {
  description = "The `core` slice of services.yaml, passed through unchanged."
  type        = any
}

variable "otel_collector" {
  description = "The infra otel-collector entry from services.yaml. One per environment, not one per pod."
  type        = any
}

variable "flavour" {
  description = "The resolved flavour object from flavours.yaml, after tfvars overrides."
  type        = any
}

variable "domain" {
  description = "Apex domain from the Route53 hosted zone."
  type        = string
}

variable "hosted_zone_id" {
  type = string
}

variable "certificate_arn" {
  description = "ACM certificate covering <domain> and *.<domain>, created in the prereq state."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr_block" {
  type = string
}

variable "public_subnet_ids" {
  description = "Where the ALB lives, always."
  type        = list(string)
}

variable "task_subnet_ids" {
  description = "Where tasks run — private or public, decided by the flavour in the network module."
  type        = list(string)
}

variable "assign_public_ip" {
  type = bool
}

variable "database_subnet_group_name" {
  type = string
}

variable "log_bucket_id" {
  type = string
}

variable "docker_registry" {
  description = "ECR registry prefix, <account>.dkr.ecr.<region>.amazonaws.com/<project>."
  type        = string
}

variable "image_tag" {
  type = string
}

variable "pods" {
  description = <<-EOT
    Every pod in this environment, so the core services can be told where they are.
    Injected as COM_ASREVO_CVHOME_PODS[n]_* into the services the catalog marks
    needs_pod_list.
  EOT
  type = map(object({
    index     = number
    id        = string
    name      = string
    endpoint  = string
    namespace = string
  }))
}

variable "test_stores" {
  description = "Activates the test-stores Spring profile. Off outside dev."
  type        = bool
  default     = false
}

variable "compute_enabled" {
  description = <<-EOT
    When false the environment is hibernated: everything billed by the hour is
    destroyed — ECS services, load balancers, NAT — while everything holding state is
    kept: RDS, S3, CloudFront, Secrets Manager, the VPC and the Cloud Map namespace.

    The kept resources are what make waking cheap and lossless. In particular the
    RDS endpoint and the CloudFront domain survive, so stored media URLs and the
    datasource host do not change under the application's feet.
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
