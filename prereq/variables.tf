variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type = string
}

variable "hosted_zone_id" {
  description = "Route53 zone to validate the certificate in. Read from SSM when not set."
  type        = string
  default     = null
}

variable "dns_prefix" {
  description = <<-EOT
    Label every hostname sits under, so environments can share a hosted zone.
    Defaults to the environment name, or "" for prod which owns the bare apex.
    Must match the env root's value — both derive it the same way.
  EOT
  type        = string
  default     = null
}

variable "image_retention_count" {
  description = "Untagged images to keep per repository before lifecycle cleanup."
  type        = number
  default     = 10
}
