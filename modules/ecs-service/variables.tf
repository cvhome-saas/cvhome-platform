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

variable "autoscaling" {
  description = <<-EOT
    Resolved scaling policy for this one service: the flavour's block with the
    catalog's per-service overrides merged over it.

    Each target is independent and optional — omit one and no policy is created for it.
    Where several are active they run together and the highest wins, which is what you
    want: whichever signal saturates first is the one that should add capacity.

      cpu_target      average CPU across the service
      memory_target   average memory; catches leaks and JVM heap pressure that CPU misses
      request_target  requests per target per minute. Only meaningful behind an
                      application load balancer, and ignored without one, because it
                      needs the ALB and target group ARN suffixes to name the metric.

    `schedules` sets min and max at fixed times — for known daily shape, not for
    reacting to load. Scaling to zero overnight keeps the URL and the load balancer up
    while paying for no tasks; hibernating takes those down too.
  EOT
  type = object({
    enabled            = bool
    min                = optional(number, 1)
    max                = optional(number, 3)
    cpu_target         = optional(number)
    memory_target      = optional(number)
    request_target     = optional(number)
    scale_in_cooldown  = optional(number, 300)
    scale_out_cooldown = optional(number, 60)
    schedules = optional(list(object({
      name     = string
      schedule = string
      timezone = optional(string, "UTC")
      min      = number
      max      = number
    })), [])
  })
  default = { enabled = false }

  validation {
    condition     = !var.autoscaling.enabled || var.autoscaling.max >= var.autoscaling.min
    error_message = "autoscaling.max must be at least autoscaling.min."
  }

  validation {
    condition = !var.autoscaling.enabled || anytrue([
      var.autoscaling.cpu_target != null,
      var.autoscaling.memory_target != null,
      var.autoscaling.request_target != null,
      length(var.autoscaling.schedules) > 0,
    ])
    error_message = "autoscaling is enabled but no target and no schedule is set, so nothing would ever scale. Set at least one of cpu_target, memory_target, request_target, or a schedule."
  }
}

variable "load_balancer_arn_suffix" {
  description = <<-EOT
    ARN suffix of the application load balancer fronting this service, needed to name
    the ALBRequestCountPerTarget metric. Null for services with no load balancer, and
    for network load balancers, which publish no per-target request count.
  EOT
  type        = string
  default     = null
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
  description = <<-EOT
    Target groups to attach, keyed arbitrarily. `arn_suffix` is only needed for
    request-count scaling; the first entry that has one is the metric's target group.
  EOT
  type = map(object({
    arn        = string
    port       = number
    arn_suffix = optional(string)
  }))
  default = {}
}

# Whether a load balancer fronts this service, and which security group it uses, are
# two separate facts. Whether is known from the catalog before anything is created;
# which is a resource attribute that does not exist until apply. They were one
# argument, so the known answer had to travel through the unknown one and the ingress
# rule below could not decide how many instances it had at plan time.
variable "load_balancer_attached" {
  description = "Whether a load balancer fronts this service. Known from configuration, so it can key a for_each."
  type        = bool
  default     = false
}

variable "load_balancer_security_group_id" {
  description = "The load balancer's SG, allowed in on the service's ports in addition to the VPC CIDR. Required when load_balancer_attached is true."
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
  description = "Identity tags for this service. Project/Environment/Flavour come from provider default_tags."
  type        = map(string)
  default     = {}
}

variable "kms_key_arns" {
  description = <<-EOT
    KMS keys this service may use. Only for services on the AWS secret-crypto provider
    (AwsKmsCryptoProvider); empty while com.asrevo.cvhome.crypto.type is LOCAL.
  EOT
  type        = list(string)
  default     = []
}

