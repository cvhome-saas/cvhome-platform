locals {
  # Services the catalog exposes at the edge, and the hosts each answers on.
  alb_services = { for name, svc in var.services : name => svc if try(svc.edge.lb, "") == "alb" }

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

  # Deterministic rule priorities: more specific hosts (more labels) first, then
  # alphabetical, so a plan never churns priorities when a service is added.
  rule_order = [
    for i, name in sort(keys(local.alb_services)) : name
  ]
}

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-${local.layer}-alb"
  description = "Public HTTP/HTTPS to the ${local.layer} load balancer"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${local.prefix}-${local.layer}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.alb.id
  description       = "Public ${each.key}"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  tags              = var.tags
}

resource "aws_vpc_security_group_egress_rule" "alb" {
  security_group_id = aws_security_group.alb.id
  description       = "To targets in the VPC"
  cidr_ipv4         = var.vpc_cidr_block
  ip_protocol       = "-1"
  tags              = var.tags
}

resource "aws_lb" "this" {
  name               = substr("${local.prefix}-core", 0, 32)
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  enable_deletion_protection = var.flavour.rds.deletion_protection
  drop_invalid_header_fields = true

  access_logs {
    enabled = true
    bucket  = var.log_bucket_id
    prefix  = "${local.layer}-alb"
  }

  tags = var.tags
}

resource "aws_lb_target_group" "service" {
  for_each = local.alb_services

  name        = substr("${local.prefix}-${each.key}", 0, 32)
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
  load_balancer_arn = aws_lb.this.arn
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
  load_balancer_arn = aws_lb.this.arn
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
  for_each = local.alb_services

  listener_arn = aws_lb_listener.https.arn
  priority     = index(local.rule_order, each.key) + 1

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
  for_each = local.records

  zone_id = var.hosted_zone_id
  name    = each.key
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}
