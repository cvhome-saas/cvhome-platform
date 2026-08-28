# A network load balancer, per pod, and it cannot be shared.
#
# spg terminates TLS itself: Caddy mints on-demand certificates for arbitrary custom
# tenant domains, which is why the listeners pass raw TCP straight through rather than
# terminating at the load balancer. A shared NLB routes by port, not by SNI-to-backend,
# and cannot express "this certificate, minted seconds ago, for a domain no
# configuration lists". Collapsing these would mean a per-environment spg fleet backed
# by pod-registry — an application change, recorded in ADR-8 but not proposed here.

locals {
  spg           = var.services["spg"]
  nlb_listeners = { for port in local.spg.edge.listeners : tostring(port) => port }
}

resource "aws_lb" "this" {
  name               = substr("${local.prefix}-${var.pod.short}", 0, 32)
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids
  internal           = false

  enable_deletion_protection       = var.flavour.rds.deletion_protection
  enable_cross_zone_load_balancing = true

  access_logs {
    enabled = true
    bucket  = var.log_bucket_id
    prefix  = "${local.layer}-nlb"
  }

  tags = var.tags
}

resource "aws_lb_target_group" "spg" {
  for_each = local.nlb_listeners

  name        = substr("${local.prefix}-${var.pod.short}-${each.key}", 0, 32)
  port        = each.value
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 30

  # Caddy's admin API on 2019 answers over plain HTTP, so it can be health-checked
  # even though 443 carries TLS that the load balancer never terminates.
  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = tostring(local.spg.edge.health_check.port)
    path                = local.spg.edge.health_check.path
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = merge(var.tags, { Service = "spg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "tcp" {
  for_each = local.nlb_listeners

  load_balancer_arn = aws_lb.this.arn
  port              = each.value
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.spg[each.key].arn
  }

  tags = var.tags
}

# The pod's own hostname, and a wildcard so every store on it resolves.
resource "aws_route53_record" "pod" {
  for_each = toset([var.pod.domain, "*.${var.pod.domain}"])

  zone_id = var.hosted_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}
