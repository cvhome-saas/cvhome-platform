# One CloudWatch dashboard per environment, built only from the metrics AWS publishes
# for free the moment a resource exists: AWS/ECS, AWS/ApplicationELB, AWS/NetworkELB,
# AWS/RDS, AWS/CloudFront, AWS/NATGateway or AWS/EC2 for a NAT instance, and the
# awslogs log groups. Nothing here
# needs Container Insights, the otel-collector or an agent, so the page reads the same
# under every flavour, including the ones with `monitoring: false`.
#
# Layout is explicit. Every widget carries x/y/width/height computed below, so an apply
# never reshuffles the page: a section is a one-row markdown header, then metric widgets
# three to a row, then (optionally) a full-width log query.

locals {
  name = "${var.project}-${var.env}"

  # Grid constants. CloudWatch dashboards are 24 columns wide.
  columns       = 3
  widget_width  = 8
  widget_height = 6
  header_height = 1
  log_height    = 6

  # ------------------------------------------------------------------ widget makers
  #
  # A metric widget is described by its title, its metric lines and the stat applied
  # to them. `metrics` follows the dashboard body syntax exactly: a list of
  # [namespace, metric, dim, value, dim, value, ..., {options}] rows.

  ecs_widgets = {
    for key, layer in merge({ core = var.core }, var.pods) : key => [
      {
        title = "ECS CPU %"
        stat  = "Average"
        metrics = [
          for s in layer.service_names :
          ["AWS/ECS", "CPUUtilization", "ClusterName", layer.cluster_name, "ServiceName", s, { label = s }]
        ]
      },
      {
        title = "ECS memory %"
        stat  = "Average"
        metrics = [
          for s in layer.service_names :
          ["AWS/ECS", "MemoryUtilization", "ClusterName", layer.cluster_name, "ServiceName", s, { label = s }]
        ]
      },
    ]
  }

  rds_widgets = {
    for key, layer in merge({ core = var.core }, var.pods) : key => [
      {
        title = "RDS CPU %"
        stat  = "Average"
        metrics = [
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", layer.db_identifier, { label = "cpu" }],
        ]
      },
      {
        title = "RDS connections"
        stat  = "Maximum"
        metrics = [
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", layer.db_identifier, { label = "connections" }],
        ]
      },
      {
        title = "RDS free memory and storage (bytes)"
        stat  = "Minimum"
        metrics = [
          ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", layer.db_identifier, { label = "freeable memory" }],
          ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", layer.db_identifier, { label = "free storage" }],
        ]
      },
      {
        title = "RDS latency (s)"
        stat  = "Average"
        metrics = [
          ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", layer.db_identifier, { label = "read" }],
          ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", layer.db_identifier, { label = "write" }],
        ]
      },
      {
        # Every flavour runs a burstable t4g class; an exhausted credit balance is the
        # usual reason a small database turns slow without its CPU graph saying so.
        title = "RDS burst credits"
        stat  = "Minimum"
        metrics = [
          ["AWS/RDS", "CPUCreditBalance", "DBInstanceIdentifier", layer.db_identifier, { label = "cpu credits" }],
          ["AWS/RDS", "BurstBalance", "DBInstanceIdentifier", layer.db_identifier, { label = "storage burst %" }],
        ]
      },
    ]
  }

  alb = var.core.alb_arn_suffix

  alb_widgets = [
    {
      title = "ALB requests and errors / min"
      stat  = "Sum"
      metrics = [
        ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb, { label = "requests" }],
        ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", local.alb, { label = "4xx (target)" }],
        ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb, { label = "5xx (target)" }],
        ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb, { label = "5xx (load balancer)" }],
      ]
    },
    {
      title = "ALB target response time (s)"
      stat  = "Average"
      metrics = [
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb, { label = "p50", stat = "p50" }],
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb, { label = "p90", stat = "p90" }],
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb, { label = "p99", stat = "p99" }],
      ]
    },
    {
      title = "ALB healthy targets"
      stat  = "Minimum"
      metrics = [
        for svc, tg in var.core.target_group_arn_suffixes :
        ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", tg, "LoadBalancer", local.alb, { label = svc }]
      ]
    },
    {
      title = "ALB unhealthy targets"
      stat  = "Maximum"
      metrics = [
        for svc, tg in var.core.target_group_arn_suffixes :
        ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", tg, "LoadBalancer", local.alb, { label = svc }]
      ]
    },
    {
      title = "ALB requests per target / min"
      stat  = "Sum"
      metrics = [
        for svc, tg in var.core.target_group_arn_suffixes :
        ["AWS/ApplicationELB", "RequestCountPerTarget", "TargetGroup", tg, "LoadBalancer", local.alb, { label = svc }]
      ]
    },
    {
      title = "ALB connections"
      stat  = "Sum"
      metrics = [
        ["AWS/ApplicationELB", "ActiveConnectionCount", "LoadBalancer", local.alb, { label = "active" }],
        ["AWS/ApplicationELB", "NewConnectionCount", "LoadBalancer", local.alb, { label = "new" }],
        ["AWS/ApplicationELB", "RejectedConnectionCount", "LoadBalancer", local.alb, { label = "rejected" }],
      ]
    },
  ]

  # A network load balancer passes TCP straight through to Caddy, so there is no
  # request count and no status code here: flows, bytes, resets and target health are
  # what it can say. Request-level numbers for a pod are Caddy's job.
  nlb_widgets = {
    for key, pod in var.pods : key => [
      {
        title = "NLB flows"
        stat  = "Sum"
        metrics = [
          ["AWS/NetworkELB", "ActiveFlowCount", "LoadBalancer", pod.nlb_arn_suffix, { label = "active", stat = "Average" }],
          ["AWS/NetworkELB", "NewFlowCount", "LoadBalancer", pod.nlb_arn_suffix, { label = "new" }],
        ]
      },
      {
        title = "NLB bytes"
        stat  = "Sum"
        metrics = [
          ["AWS/NetworkELB", "ProcessedBytes", "LoadBalancer", pod.nlb_arn_suffix, { label = "processed" }],
        ]
      },
      {
        title = "NLB resets"
        stat  = "Sum"
        metrics = [
          ["AWS/NetworkELB", "TCP_Client_Reset_Count", "LoadBalancer", pod.nlb_arn_suffix, { label = "client" }],
          ["AWS/NetworkELB", "TCP_Target_Reset_Count", "LoadBalancer", pod.nlb_arn_suffix, { label = "target" }],
          ["AWS/NetworkELB", "TCP_ELB_Reset_Count", "LoadBalancer", pod.nlb_arn_suffix, { label = "load balancer" }],
        ]
      },
      {
        title = "NLB healthy spg targets"
        stat  = "Minimum"
        metrics = [
          for port, tg in pod.nlb_target_group_arn_suffixes :
          ["AWS/NetworkELB", "HealthyHostCount", "TargetGroup", tg, "LoadBalancer", pod.nlb_arn_suffix, { label = "port ${port}" }]
        ]
      },
      {
        title = "NLB unhealthy spg targets"
        stat  = "Maximum"
        metrics = [
          for port, tg in pod.nlb_target_group_arn_suffixes :
          ["AWS/NetworkELB", "UnHealthyHostCount", "TargetGroup", tg, "LoadBalancer", pod.nlb_arn_suffix, { label = "port ${port}" }]
        ]
      },
    ]
  }

  # CloudFront is global and reports to us-east-1 whatever region the stack is in.
  cdn_widgets = {
    for key, pod in var.pods : key => [
      {
        title  = "CDN requests / min"
        stat   = "Sum"
        region = "us-east-1"
        metrics = [
          ["AWS/CloudFront", "Requests", "DistributionId", pod.cdn_distribution_id, "Region", "Global", { label = "requests" }],
        ]
      },
      {
        title  = "CDN error rate %"
        stat   = "Average"
        region = "us-east-1"
        metrics = [
          ["AWS/CloudFront", "4xxErrorRate", "DistributionId", pod.cdn_distribution_id, "Region", "Global", { label = "4xx" }],
          ["AWS/CloudFront", "5xxErrorRate", "DistributionId", pod.cdn_distribution_id, "Region", "Global", { label = "5xx" }],
        ]
      },
      {
        title  = "CDN bytes"
        stat   = "Sum"
        region = "us-east-1"
        metrics = [
          ["AWS/CloudFront", "BytesDownloaded", "DistributionId", pod.cdn_distribution_id, "Region", "Global", { label = "downloaded" }],
          ["AWS/CloudFront", "BytesUploaded", "DistributionId", pod.cdn_distribution_id, "Region", "Global", { label = "uploaded" }],
        ]
      },
    ]
  }

  nat_widgets = var.nat_gateway_id == null ? [] : [
    {
      title = "NAT bytes"
      stat  = "Sum"
      metrics = [
        ["AWS/NATGateway", "BytesOutToDestination", "NatGatewayId", var.nat_gateway_id, { label = "out to internet" }],
        ["AWS/NATGateway", "BytesInFromDestination", "NatGatewayId", var.nat_gateway_id, { label = "in from internet" }],
      ]
    },
    {
      title = "NAT connections"
      stat  = "Sum"
      metrics = [
        ["AWS/NATGateway", "ActiveConnectionCount", "NatGatewayId", var.nat_gateway_id, { label = "active", stat = "Maximum" }],
        ["AWS/NATGateway", "ConnectionAttemptCount", "NatGatewayId", var.nat_gateway_id, { label = "attempts" }],
      ]
    },
    {
      # Both of these are zero on a healthy gateway. ErrorPortAllocation is port
      # exhaustion; PacketsDropCount is the gateway itself failing.
      title = "NAT errors"
      stat  = "Sum"
      metrics = [
        ["AWS/NATGateway", "ErrorPortAllocation", "NatGatewayId", var.nat_gateway_id, { label = "port allocation errors" }],
        ["AWS/NATGateway", "PacketsDropCount", "NatGatewayId", var.nat_gateway_id, { label = "packets dropped" }],
      ]
    },
  ]

  # Below prod the NAT is one EC2 instance, and every private task depends on it. Basic
  # monitoring publishes every five minutes, so these widgets ask for five-minute points.
  nat_instance_widgets = var.nat_instance_id == null ? [] : [
    {
      title  = "NAT instance bytes"
      stat   = "Sum"
      period = 300
      metrics = [
        ["AWS/EC2", "NetworkOut", "InstanceId", var.nat_instance_id, { label = "out" }],
        ["AWS/EC2", "NetworkIn", "InstanceId", var.nat_instance_id, { label = "in" }],
      ]
    },
    {
      # A t4g earns CPU credits slowly; a balance at zero is a NAT that has started to crawl.
      title  = "NAT instance CPU"
      stat   = "Average"
      period = 300
      metrics = [
        ["AWS/EC2", "CPUUtilization", "InstanceId", var.nat_instance_id, { label = "cpu %" }],
        ["AWS/EC2", "CPUCreditBalance", "InstanceId", var.nat_instance_id, { label = "credit balance", yAxis = "right" }],
      ]
    },
    {
      # Zero on a healthy instance. Anything else and the private tasks have lost the internet.
      title  = "NAT instance status checks failed"
      stat   = "Maximum"
      period = 300
      metrics = [
        ["AWS/EC2", "StatusCheckFailed", "InstanceId", var.nat_instance_id, { label = "failed" }],
      ]
    },
  ]

  # ---------------------------------------------------------------------- sections
  #
  # In reading order: the core layer, then each pod, then the network the flavour
  # shares between them. Each section ends with the layer's error log.

  sections = concat(
    [
      {
        title      = "store-core - cluster ${var.core.cluster_name}"
        widgets    = concat(local.ecs_widgets["core"], local.alb_widgets, local.rds_widgets["core"])
        log_groups = values(var.core.log_group_names)
      },
    ],
    [
      for key in sort(keys(var.pods)) : {
        title      = "${var.pods[key].name} - cluster ${var.pods[key].cluster_name}"
        widgets    = concat(local.ecs_widgets[key], local.nlb_widgets[key], local.cdn_widgets[key], local.rds_widgets[key])
        log_groups = values(var.pods[key].log_group_names)
      }
    ],
    var.nat_gateway_id == null ? [] : [
      {
        title      = "network - NAT gateway ${var.nat_gateway_id}"
        widgets    = local.nat_widgets
        log_groups = []
      },
    ],
    var.nat_instance_id == null ? [] : [
      {
        title      = "network - NAT instance ${var.nat_instance_id}"
        widgets    = local.nat_instance_widgets
        log_groups = []
      },
    ],
  )

  # ------------------------------------------------------------------------ layout

  section_heights = [
    for s in local.sections :
    local.header_height
    + ceil(length(s.widgets) / local.columns) * local.widget_height
    + (length(s.log_groups) > 0 ? local.log_height : 0)
  ]

  section_offsets = [
    for i in range(length(local.sections)) : sum(concat([0], slice(local.section_heights, 0, i)))
  ]

  # Logs Insights over every log group of the layer, newest first. Spring logs at
  # ERROR level; Node and Caddy print stack traces and "error" in lower case.
  log_query = "fields @timestamp, @logStream, @message | filter @message like /(?i)error|exception/ | sort @timestamp desc | limit 50"

  widgets = flatten([
    for i, s in local.sections : concat(
      [
        {
          type   = "text"
          x      = 0
          y      = local.section_offsets[i]
          width  = 24
          height = local.header_height
          properties = {
            markdown = "## ${s.title}"
          }
        },
      ],
      [
        for j, w in s.widgets : {
          type   = "metric"
          x      = (j % local.columns) * local.widget_width
          y      = local.section_offsets[i] + local.header_height + floor(j / local.columns) * local.widget_height
          width  = local.widget_width
          height = local.widget_height
          properties = {
            title   = w.title
            region  = try(w.region, var.region)
            view    = "timeSeries"
            stacked = false
            period  = try(w.period, 60)
            stat    = w.stat
            metrics = w.metrics
            yAxis   = { left = { min = 0 } }
          }
        }
      ],
      length(s.log_groups) == 0 ? [] : [
        {
          type   = "log"
          x      = 0
          y      = local.section_offsets[i] + local.header_height + ceil(length(s.widgets) / local.columns) * local.widget_height
          width  = 24
          height = local.log_height
          properties = {
            title  = "Recent errors"
            region = var.region
            view   = "table"
            query  = "${join(" | ", [for g in sort(s.log_groups) : "SOURCE '${g}'"])} | ${local.log_query}"
          }
        },
      ],
    )
  ])
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name

  dashboard_body = jsonencode({
    widgets = local.widgets
  })
}
