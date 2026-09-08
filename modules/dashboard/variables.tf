variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  description = "Where the metrics live. CloudFront's are queried from us-east-1 regardless."
  type        = string
}

variable "core" {
  description = "What store-core exposes: the identifiers that name its metrics."
  type = object({
    cluster_name              = string
    service_names             = list(string)
    alb_arn_suffix            = string
    target_group_arn_suffixes = map(string)
    db_identifier             = string
    log_group_names           = map(string)
  })
}

variable "pods" {
  description = "One entry per pod, keyed as main.tf keys them (pod-1, pod-2, ...)."
  type = map(object({
    name                          = string
    cluster_name                  = string
    service_names                 = list(string)
    nlb_arn_suffix                = string
    nlb_target_group_arn_suffixes = map(string)
    db_identifier                 = string
    cdn_distribution_id           = string
    log_group_names               = map(string)
  }))
}

variable "nat_gateway_id" {
  description = "The environment's NAT gateway, when the flavour runs one. Null otherwise, and the section is omitted."
  type        = string
  default     = null
}
