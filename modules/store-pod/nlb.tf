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
  # name_prefix, not a truncated name: substr() silently produced colliding names once
  # project+env grew, and could end on a hyphen, which AWS rejects outright.
  # AWS appends uniqueness, so the prefix must leave room (<= 6 characters).
  name_prefix        = "p${substr(var.pod.short, 0, 5)}"
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids
  internal           = false

  enable_deletion_protection       = var.flavour.protected
  enable_cross_zone_load_balancing = true

  # No access_logs block. Network load balancers only write access logs for TLS
  # listeners, and these are deliberate TCP passthrough so Caddy can terminate TLS
  # itself. Enabling it produced nothing while still requiring a bucket policy that,
  # if wrong, fails load balancer creation. Request logging for a pod is Caddy's job.

  tags = var.tags
}

resource "aws_lb_target_group" "spg" {
  for_each = local.nlb_listeners

  name_prefix = "t${substr(each.key, 0, 4)}"
  port        = each.value
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 30

  # Stated rather than inherited. With client IP preservation off, targets see the
  # load balancer's private address, which is why spg's security group can admit the
  # VPC CIDR alone. Turning this on would require opening 80/443 to 0.0.0.0/0 on spg —
  # so the two settings are coupled and neither should drift silently.
  preserve_client_ip = false

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

# The pod's own hostname, and a wildcard so every custom tenant domain on it resolves.
#
# Fully qualified against the environment's domain, not the bare zone: with env-scoped
# hostnames the pod lives at spg-<id>.dev.example.com, and a bare label would have
# created spg-<id>.example.com instead — matching what the tasks were told their
# endpoint is only by accident in prod.
resource "aws_route53_record" "pod" {
  for_each = toset([local.pod_fqdn, "*.${local.pod_fqdn}"])

  zone_id = var.hosted_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}
