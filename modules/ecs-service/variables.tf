variable "name" {
  description = "Service name. Also the Cloud Map service name, so `lb://<name>` resolves."
  type        = string
}

variable "project" {
  description = "Stable project identifier. Not random — see ADR-6."
  type        = string
}

variable "env" {
  description = "Environment name. A real parameter, unlike the legacy hardcoded \"dev\"."
  type        = string
}

variable "layer" {
  description = "Owning layer, used in resource names and the log group path (store-core, store-pod-<id>)."
  type        = string
}

variable "cluster_name" {
  type = string
}

variable "namespace_id" {
  description = "Cloud Map private DNS namespace to register in."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr_block" {
  description = "Source CIDR for in-VPC service-to-service traffic."
  type        = string
}

variable "subnets" {
  type = list(string)
}

variable "assign_public_ip" {
  description = <<-EOT
    Whether tasks get a public IP. False requires NAT for egress, so it is driven by the
    flavour's private_tasks: prod runs private, dev and staging do not.
  EOT
  type        = bool
}

# --- container -------------------------------------------------------------------

variable "image" {
  description = "Fully qualified image URI including tag."
  type        = string
}

variable "ports" {
  description = <<-EOT
    Every port the container listens on. Usually one; spg listens on 80, 443 and 2019
    (Caddy's admin API, which the NLB health-checks). The security group opens exactly
    these — the legacy module opened 0-65535 to the whole VPC.
  EOT
  type        = list(number)
}

variable "environment" {
  description = "Plain environment variables. Computed once by the caller, never per-service copy-paste."
  type        = list(object({ name = string, value = string }))
  default     = []
}

variable "secrets" {
  description = "Secret env, as ECS secret references (arn:json-key::)."
  type        = list(object({ name = string, valueFrom = string }))
  default     = []
}

# --- flavour ---------------------------------------------------------------------

variable "cpu" {
  type = number
}

variable "memory" {
  type = number
}

variable "desired_count" {
  type = number
}

variable "autoscale" {
  type    = bool
  default = false
}

variable "capacity" {
  description = <<-EOT
    Fargate capacity split. on_demand_base tasks run on-demand before any Spot is used;
    on_demand_percent splits everything above the base. The legacy module hardcoded
    FARGATE_SPOT at weight 100 with no base, so at desired=1 a reclamation was an outage.
  EOT
  type = object({
    on_demand_base    = number
    on_demand_percent = number
  })
}

variable "health_check_grace_seconds" {
  description = <<-EOT
    Grace period before the load balancer's verdict can kill a task. The legacy module
    set 0 on Spring Boot services that take tens of seconds to become healthy.
  EOT
  type        = number
  default     = 90
}

variable "log_retention_days" {
  type    = number
  default = 14
}

# --- edge ------------------------------------------------------------------------

variable "target_groups" {
  description = "Target group ARNs to attach, keyed arbitrarily, each with the container port it serves."
  type        = map(object({ arn = string, port = number }))
  default     = {}
}

variable "load_balancer_security_group_id" {
  description = "When set, the load balancer's SG is allowed in on the service's ports in addition to the VPC CIDR."
  type        = string
  default     = null
}

# --- iam -------------------------------------------------------------------------

variable "secret_arns" {
  description = <<-EOT
    Secrets Manager ARNs this service may read. Scoped deliberately: the legacy roles
    granted secretsmanager:*, ssm:* and s3:* on "*" to every task in the account.
  EOT
  type        = list(string)
  default     = []
}

variable "s3_bucket_arns" {
  description = "S3 buckets this service may read and write (CDN storage, Caddy cert storage)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type = map(string)
}
