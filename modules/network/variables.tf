variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "cidr_block" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  description = "Availability zones to spread across. Two is enough for RDS; three costs more NAT under prod."
  type        = number
  default     = 2
}

variable "egress" {
  description = <<-EOT
    From the flavour's network.egress: how tasks reach the internet.

      public_ip     tasks sit in public subnets, each with a public IPv4 of its own; no NAT
      nat_instance  tasks sit in private subnets behind one EC2 NAT instance
      nat_gateway   tasks sit in private subnets behind one managed NAT gateway

    AWS bills every public IPv4 by the hour, in use or idle ($0.005/h in us-east-1), so
    one address on a NAT instance costs less than one per task past two or three tasks.
    The gateway costs more than either and buys managed availability, which is what prod
    pays for.
  EOT
  type        = string

  validation {
    condition     = contains(["public_ip", "nat_instance", "nat_gateway"], var.egress)
    error_message = "egress must be public_ip, nat_instance or nat_gateway."
  }
}

variable "nat_instance_type" {
  description = "EC2 type of the NAT instance under egress = nat_instance. The AL2023 image follows its architecture."
  type        = string
  default     = "t4g.nano"
}

variable "compute_enabled" {
  description = "When false, the NAT goes, gateway or instance. Subnets and the VPC itself are free and stay."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra identity tags. Project/Environment/Flavour arrive via provider default_tags."
  type        = map(string)
  default     = {}
}
