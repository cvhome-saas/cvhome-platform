# Per-pod RDS: isolation over cost (ADR-7). This is the term that scales with pod count.

resource "aws_security_group" "db" {
  name        = "${local.prefix}-${local.layer}-db"
  description = "Postgres for pod ${var.pod.name}, reachable only from this pod's tasks"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${local.prefix}-${local.layer}-db" })
}

resource "aws_vpc_security_group_ingress_rule" "db" {
  for_each = module.service

  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from ${each.key}"
  referenced_security_group_id = each.value.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  tags                         = var.tags
}

resource "aws_db_instance" "this" {
  identifier = substr("${local.prefix}-${local.layer}", 0, 63)

  engine         = "postgres"
  engine_version = "18.4"
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
  vpc_security_group_ids = [aws_security_group.db.id]
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
