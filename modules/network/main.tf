data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  prefix = "${var.project}-${var.env}"
  azs    = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /20 per subnet: 4093 usable addresses, comfortably more than Fargate ENIs need,
  # and it leaves room to add tiers without renumbering.
  public   = [for i, _ in local.azs : cidrsubnet(var.cidr_block, 4, i)]
  private  = [for i, _ in local.azs : cidrsubnet(var.cidr_block, 4, i + 4)]
  database = [for i, _ in local.azs : cidrsubnet(var.cidr_block, 4, i + 8)]

  # One NAT, not one per AZ. A second costs the same again to protect against an AZ
  # failure that would already have degraded the service.
  create_nat = var.private_tasks && var.nat_gateway
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = local.prefix })

  lifecycle {
    precondition {
      condition     = !(var.nat_gateway && !var.private_tasks)
      error_message = "nat_gateway is set without private_tasks: the NAT would be billed hourly and route nothing. Set private_tasks, or turn the NAT off."
    }
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = local.prefix })
}

# --- subnets ---------------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = local.public[each.value]

  # Load balancers always live here. Tasks join them only when private_tasks is false.
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${local.prefix}-public-${each.key}", Tier = "public" })
}

resource "aws_subnet" "private" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = local.private[each.value]

  tags = merge(var.tags, { Name = "${local.prefix}-private-${each.key}", Tier = "private" })
}

resource "aws_subnet" "database" {
  for_each = { for i, az in local.azs : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = local.database[each.value]

  tags = merge(var.tags, { Name = "${local.prefix}-database-${each.key}", Tier = "database" })
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.prefix}-db"
  subnet_ids = [for s in aws_subnet.database : s.id]
  tags       = var.tags
}

# --- routing ---------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.prefix}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.create_nat ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${local.prefix}-nat" })
}

resource "aws_nat_gateway" "this" {
  count = local.create_nat ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = values(aws_subnet.public)[0].id
  tags          = merge(var.tags, { Name = local.prefix })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.prefix}-private" })
}

resource "aws_route" "private_nat" {
  count = local.create_nat ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# Database subnets get no route off the VPC at all.
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.prefix}-database" })
}

resource "aws_route_table_association" "database" {
  for_each = aws_subnet.database

  subnet_id      = each.value.id
  route_table_id = aws_route_table.database.id
}
