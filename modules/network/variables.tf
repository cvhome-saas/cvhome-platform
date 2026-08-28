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

variable "private_tasks" {
  description = <<-EOT
    From the flavour. When true, tasks run in private subnets and egress through NAT.
    When false they sit in public subnets with public IPs and no NAT is created —
    NAT is real money, and below prod the narrowed per-service security groups do the
    load-bearing work.
  EOT
  type        = bool
}

variable "nat_gateway" {
  description = "Create a NAT gateway. Meaningless without private_tasks; validated below."
  type        = bool
}

variable "tags" {
  type = map(string)
}
