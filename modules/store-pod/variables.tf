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

variable "log_bucket_id" {
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

variable "tags" {
  type = map(string)
}
