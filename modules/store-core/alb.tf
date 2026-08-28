locals {
  # Services the catalog exposes at the edge, and the hosts each answers on.
  alb_services = { for name, svc in var.services : name => svc if try(svc.edge.lb, "") == "alb" }

  # Everything the load balancer owns disappears while hibernated. The hostnames above
  # are still computed, so `terraform output urls` keeps telling you what the
  # environment answers on once it is awake.
  active_alb_services = { for name, svc in local.alb_services : name => svc if var.compute_enabled }
  active_records      = { for host, svc in local.records : host => svc if var.compute_enabled }

  # "@" means the apex. Everything else is a subdomain label.
  host_fqdn = {
    for name, svc in local.alb_services : name => [
      for h in svc.edge.hosts : h == "@" ? var.domain : "${h}.${var.domain}"
    ]
  }

  # Flattened for Route53: one record per hostname, pointing at the ALB.
  # Because these come from the catalog, a renamed service cannot leave a stale record
  # behind — which is exactly how `seller-ui` survived the rename to `console-ui`.
  records = merge([
    for name, hosts in local.host_fqdn : {
      for h in hosts : h => name
    }
  ]...)

  # Priorities come from the catalog, not from position. They were derived with
  # index(sort(keys(...))), so adding any service that sorted earlier renumbered every
  # rule after it — the opposite of what the comment here used to claim.
}

resource "aws_security_group" "alb" {
  count = var.compute_enabled ? 1 : 0

  name        = "${local.prefix}-${local.layer}-alb"
  description = "Public HTTP/HTTPS to the ${local.layer} load balancer"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${local.prefix}-${local.layer}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each = { for k, v in { http = 80, https = 443 } : k => v if var.compute_enabled }

  security_group_id = aws_security_group.alb[0].id
  description       = "Public ${each.key}"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  tags              = var.tags
}

resource "aws_vpc_security_group_egress_rule" "alb" {
  count = var.compute_enabled ? 1 : 0

  security_group_id = aws_security_group.alb[0].id
  description       = "To targets in the VPC"
  cidr_ipv4         = var.vpc_cidr_block
  ip_protocol       = "-1"
  tags              = var.tags
}

resource "aws_lb" "this" {
  count = var.compute_enabled ? 1 : 0

  # name_prefix (max 6) rather than a truncated name. substr() to 32 already overflowed
  # at project "cvhome" + env "staging", and could truncate onto a hyphen, which AWS
  # rejects. AWS appends the uniqueness suffix itself.
  name_prefix        = "core-"
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb[0].id]

  enable_deletion_protection = var.flavour.protected
  drop_invalid_header_fields = true

  access_logs {
    enabled = true
    bucket  = var.log_bucket_id
    prefix  = "${local.layer}-alb"
  }

  tags = var.tags
}

resource "aws_lb_target_group" "service" {
  for_each = local.active_alb_services

  # Also name_prefix: with a fixed name, create_before_destroy could never replace a
  # target group — the new one collided with the old one's name.
  name_prefix = substr(replace(each.key, "-", ""), 0, 5)
  port        = each.value.port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  # Spring Boot needs a moment; give it a real window rather than the legacy zero.
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = each.value.runtime == "spring" ? "/actuator/health" : "/"
    port                = tostring(each.value.port)
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200"
  }

  tags = merge(var.tags, { Service = each.key })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  count = var.compute_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  count = var.compute_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  # Anything that matches no rule gets an honest 404 rather than reaching a service.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "No route for this host."
      status_code  = "404"
    }
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "host" {
  for_each = local.active_alb_services

  listener_arn = aws_lb_listener.https[0].arn
  priority     = each.value.edge.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }

  condition {
    host_header {
      values = local.host_fqdn[each.key]
    }
  }

  tags = merge(var.tags, { Service = each.key })
}

# --------------------------------------------------------------------------- dns

resource "aws_route53_record" "service" {
  for_each = local.active_records

  zone_id = var.hosted_zone_id
  name    = each.key
  type    = "A"

  alias {
    name                   = aws_lb.this[0].dns_name
    zone_id                = aws_lb.this[0].zone_id
    evaluate_target_health = false
  }
}
