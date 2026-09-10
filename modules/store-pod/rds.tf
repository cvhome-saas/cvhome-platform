# Per-pod RDS: isolation over cost (ADR-7). This is the term that scales with pod count.
#
# Below prod the default pod can use store-core's instance instead (flavour rds.shared,
# passed in as database_shared). Every service owns a schema named after itself
# (hikari.schema is spring.application.name), so core's four database services and one
# pod's seven sit side by side on one database, as all of them already do under lcl. A
# second pod's schemas would collide with the first's, so only the default pod shares.

moved {
  from = aws_security_group.db
  to   = aws_security_group.db[0]
}

moved {
  from = aws_db_instance.this
  to   = aws_db_instance.this[0]
}

resource "aws_security_group" "db" {
  count = var.database_shared ? 0 : 1

  name = "${local.prefix}-${local.layer}-db"
  # No apostrophe: EC2 rejects it in a security group description.
  description = "Postgres for pod ${var.pod.name}, reachable only from tasks in this pod"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${local.prefix}-${local.layer}-db" })
}

# On the pod's own security group, or on core's when the pod shares its database.
resource "aws_vpc_security_group_ingress_rule" "db" {
  for_each = module.service

  security_group_id            = local.db.security_group_id
  description                  = var.database_shared ? "Postgres from ${var.pod.name} ${each.key}" : "Postgres from ${each.key}"
  referenced_security_group_id = each.value.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  tags                         = var.tags
}

resource "aws_db_instance" "this" {
  count = var.database_shared ? 0 : 1

  identifier = substr("${local.prefix}-${local.layer}", 0, 63)

  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.flavour.rds.instance_class

  allocated_storage     = var.flavour.rds.allocated_storage
  max_allocated_storage = var.flavour.rds.max_allocated_storage > 0 ? var.flavour.rds.max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = var.flavour.rds.storage_encrypted

  db_name  = "postgres"
  username = "postgres"
  port     = 5432

  manage_master_user_password = true

  db_subnet_group_name   = var.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db[0].id]
  publicly_accessible    = false

  multi_az                     = var.flavour.rds.multi_az
  backup_retention_period      = var.flavour.rds.backup_retention_days
  deletion_protection          = var.flavour.rds.deletion_protection
  skip_final_snapshot          = var.flavour.rds.skip_final_snapshot
  final_snapshot_identifier    = var.flavour.rds.skip_final_snapshot ? null : substr("${local.prefix}-${local.layer}-final", 0, 63)
  performance_insights_enabled = var.flavour.rds.performance_insights

  auto_minor_version_upgrade = true
  apply_immediately          = !var.flavour.rds.deletion_protection

  tags = var.tags
}

locals {
  # The database this pod's services are wired to: its own, or store-core's.
  db = var.database_shared ? var.shared_database : {
    identifier        = aws_db_instance.this[0].identifier
    address           = aws_db_instance.this[0].address
    port              = aws_db_instance.this[0].port
    db_name           = aws_db_instance.this[0].db_name
    username          = aws_db_instance.this[0].username
    secret_arn        = aws_db_instance.this[0].master_user_secret[0].secret_arn
    security_group_id = aws_security_group.db[0].id
  }
}
