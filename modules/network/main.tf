data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  prefix = "${var.project}-${var.env}"
  azs    = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /20 per subnet: 4093 usable addresses, comfortably more than Fargate ENIs need,
  # and it leaves room to add tiers without renumbering.
  public   = [for i, _ in local.azs : cidrsubnet(var.cidr_block, 4, i)]
  private  = [for i, _ in local.azs : cidrsubnet(var.cidr_block, 4, i + 4)]
  database = [for i, _ in local.azs : cidrsubnet(var.cidr_block, 4, i + 8)]

  # Tasks sit in private subnets unless each is to carry a public address of its own.
  private_tasks = var.egress != "public_ip"

  # One NAT, not one per AZ. A second costs the same again to protect against an AZ
  # failure that would already have degraded the service. Either kind goes while
  # hibernated; its security group and the S3 endpoint are free and stay.
  create_nat_gateway  = var.egress == "nat_gateway" && var.compute_enabled
  create_nat_instance = var.egress == "nat_instance" && var.compute_enabled

  # What the NAT instance's user data prints last, and what terraform_data.nat_ready
  # waits to read on its console.
  nat_ready_marker = "cvhome-nat-ready"
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = local.prefix })
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

  # Load balancers and the NAT always live here. Tasks join them only under egress =
  # public_ip, and then ask for their own address.
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
  count  = local.create_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${local.prefix}-nat" })
}

resource "aws_nat_gateway" "this" {
  count = local.create_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = values(aws_subnet.public)[0].id
  tags          = merge(var.tags, { Name = local.prefix })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.prefix}-private" })
}

# One route whichever kind of NAT carries it, so switching between the two is an
# in-place ReplaceRoute rather than a delete racing a create for the same destination.
resource "aws_route" "private_nat" {
  count = local.create_nat_gateway || local.create_nat_instance ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = local.create_nat_gateway ? aws_nat_gateway.this[0].id : null
  network_interface_id   = local.create_nat_instance ? aws_instance.nat[0].primary_network_interface_id : null

  depends_on = [terraform_data.nat_ready]
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

# ECR serves image layers out of S3, so a gateway endpoint keeps image pulls off the
# NAT instance's few megabits of baseline bandwidth. Gateway endpoints are free. Only
# with the NAT instance for now: adding it under the gateway would change prod.
resource "aws_vpc_endpoint" "s3" {
  count = var.egress == "nat_instance" ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.tags, { Name = "${local.prefix}-s3" })
}

# --- NAT instance ----------------------------------------------------------------
#
# The gateway's job for a fraction of its price: a t4g.nano is $0.0042/h against the
# gateway's $0.045/h plus $0.045/GB (us-east-1 list). What it gives up is managed
# availability. If the instance fails, every private task loses the internet (image
# pulls, Secrets Manager, CloudWatch Logs, Cloud Map DiscoverInstances, Stripe, ACME)
# until EC2 recovers it. Below prod that is the right trade; prod keeps the gateway.
#
# AWS's recipe on AWS's image: AL2023 and the steps of the VPC guide's "Create a NAT
# AMI", not a community NAT image. No instance profile and no key pair; nothing on
# the instance needs either.

data "aws_ec2_instance_type" "nat" {
  count = local.create_nat_instance ? 1 : 0

  instance_type = var.nat_instance_type
}

data "aws_ami" "nat" {
  count = local.create_nat_instance ? 1 : 0

  owners      = ["amazon"]
  most_recent = true

  # The standard image, for whichever architecture the instance type runs; the name
  # pattern leaves out the minimal and ECS-optimised variants.
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-${local.nat_architecture}"]
  }

  filter {
    name   = "architecture"
    values = [local.nat_architecture]
  }
}

locals {
  nat_architecture = local.create_nat_instance ? (
    contains(data.aws_ec2_instance_type.nat[0].supported_architectures, "arm64") ? "arm64" : "x86_64"
  ) : null
}

resource "aws_security_group" "nat" {
  count = var.egress == "nat_instance" ? 1 : 0

  name        = "${local.prefix}-nat"
  description = "NAT instance - anything from inside the VPC, out to the internet"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${local.prefix}-nat" })
}

resource "aws_vpc_security_group_ingress_rule" "nat" {
  count = var.egress == "nat_instance" ? 1 : 0

  security_group_id = aws_security_group.nat[0].id
  description       = "Whatever the private subnets send out"
  cidr_ipv4         = var.cidr_block
  ip_protocol       = "-1"

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "nat" {
  count = var.egress == "nat_instance" ? 1 : 0

  security_group_id = aws_security_group.nat[0].id
  description       = "Out to the internet, on behalf of the private subnets"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = var.tags
}

resource "aws_instance" "nat" {
  count = local.create_nat_instance ? 1 : 0

  ami                    = data.aws_ami.nat[0].id
  instance_type          = var.nat_instance_type
  subnet_id              = values(aws_subnet.public)[0].id
  vpc_security_group_ids = [aws_security_group.nat[0].id]

  # One public address for the whole environment, where egress = public_ip spends one
  # per task. A NAT forwards packets addressed to other hosts, which the source/dest
  # check would drop.
  associate_public_ip_address = true
  source_dest_check           = false

  user_data = templatefile("${path.module}/nat-instance.sh.tftpl", {
    instance_type = var.nat_instance_type
    vpc_cidr      = var.cidr_block
    ready_marker  = local.nat_ready_marker
  })
  user_data_replace_on_change = true

  # IMDSv2 only. It stays enabled because cloud-init reads the user data from it.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${local.prefix}-nat" })

  lifecycle {
    # A newer AL2023 image is not a reason to cut every task off mid-apply. Re-image
    # deliberately with `terraform apply -replace`.
    ignore_changes = [ami]
    # A replacement comes up, reports ready and takes the route before the old one goes.
    create_before_destroy = true
  }
}

# The instance reports running long before it forwards a packet. Services moved into
# the private subnets inside that window fail their image pulls and trip the circuit
# breaker, so the route above waits until the user data has printed its last line.
# It needs the AWS CLI wherever Terraform runs: CodeBuild has it, and so does anyone
# running scripts/hibernate.sh or wake.sh.
resource "terraform_data" "nat_ready" {
  count = local.create_nat_instance ? 1 : 0

  triggers_replace = [aws_instance.nat[0].id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      command -v aws >/dev/null || { echo "The AWS CLI is needed to wait for the NAT instance $INSTANCE." >&2; exit 1; }
      for attempt in $(seq 1 60); do
        if aws ec2 get-console-output --latest --region "$REGION" --instance-id "$INSTANCE" \
          --query Output --output text 2>/dev/null | grep -q "$MARKER"; then
          echo "NAT instance $INSTANCE is forwarding."
          exit 0
        fi
        sleep 10
      done
      echo "NAT instance $INSTANCE did not report ready within 10 minutes. Read its system log in the EC2 console." >&2
      exit 1
    EOT

    environment = {
      INSTANCE = aws_instance.nat[0].id
      REGION   = data.aws_region.current.region
      MARKER   = local.nat_ready_marker
    }
  }
}
