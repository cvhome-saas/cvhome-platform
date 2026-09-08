# CloudWatch dashboard from the metrics AWS publishes by default

## Context

An environment has no single place to look at. `flavours.yaml` has a `monitoring` flag that turns on
Container Insights, the otel-collector and OTLP export (`modules/store-core/main.tf:23`,
`modules/store-pod/main.tf:276`), but nothing renders any of it, and under `dev` and `ephemeral` the flag
is off. Meanwhile every environment already emits metrics that cost nothing and need no agent:

| Namespace | Dimensions we already know | Created by |
|---|---|---|
| `AWS/ECS` CPUUtilization, MemoryUtilization | ClusterName, ServiceName | `modules/ecs-service/main.tf:170` (`aws_ecs_service`) |
| `AWS/ApplicationELB` RequestCount, TargetResponseTime, HTTPCode_*, HealthyHostCount | LoadBalancer (`arn_suffix`), TargetGroup (`arn_suffix`) | `modules/store-core/alb.tf` |
| `AWS/NetworkELB` ActiveFlowCount, NewFlowCount, ProcessedBytes, HealthyHostCount, TCP_Target_Reset_Count | LoadBalancer, TargetGroup | `modules/store-pod/nlb.tf` |
| `AWS/RDS` CPUUtilization, DatabaseConnections, FreeableMemory, FreeStorageSpace, Read/WriteLatency, CPUCreditBalance | DBInstanceIdentifier | `modules/store-{core,pod}/rds.tf` |
| `AWS/CloudFront` Requests, BytesDownloaded, 4xx/5xxErrorRate | DistributionId, Region=Global (us-east-1) | `modules/store-pod/storage.tf:85` |
| `AWS/NATGateway` BytesOutToDestination, ErrorPortAllocation, PacketsDropCount | NatGatewayId | `modules/network/main.tf:107` (prod only) |
| CloudWatch Logs (awslogs driver) | log group per service | `modules/ecs-service/main.tf:96` |

Nothing here depends on `flavour.monitoring`; it is what every account gets the moment the resources exist.

## Why the design is what it is

- **One dashboard per environment, not per layer.** An operator asks "is dev healthy", not "is pod-1's
  NLB healthy". Layers become rows: store-core, then one row group per pod, then shared network.
- **A module (`modules/dashboard`) fed by outputs.** The identifiers a widget needs (cluster name, ALB and
  target-group suffixes, RDS identifier, CloudFront id, NAT id) are attributes of resources in three other
  modules. Assembling widgets at the root from those outputs keeps the layer modules ignorant of
  dashboards and keeps one file responsible for layout.
- **A flavour key, not a variable.** `dashboard: true|false` in `flavours.yaml`, on for dev/staging/prod
  and off for ephemeral (throwaway environments do not need a saved page; CloudWatch bills dashboards
  beyond a per-account free allowance, which the pricing MCP was down to confirm). Overridable per env via
  `flavour_overrides` like every other key.
- **Absent while hibernated.** The ALB, NLBs and services are destroyed while `hibernated = true`, and their
  `arn_suffix` values are null, so the dashboard is gated on `compute_enabled` like the rest of the hourly
  things. It comes back on wake with the same name.
- **Only default metrics.** No Container Insights (`ECS/ContainerInsights`) widgets even where
  `monitoring: true`, so the page reads the same in every flavour. Adding those is a later, separate row.
- **Deterministic layout.** Widgets carry explicit `x/y/width/height` computed in locals, so an apply
  never reshuffles the page; each section is a markdown header row followed by 8-wide metric widgets.
- **Alarms are out of scope.** This is the page; alarms need SLO decisions that belong with load-testing's
  thresholds and are a separate plan.

## Phase 1 — the dashboard (PR 1)

- `flavours.yaml`: `dashboard` under all four flavours.
- `modules/store-core/outputs.tf`: `cluster_name`, `alb_arn_suffix` (null while hibernated),
  `target_group_arn_suffixes`, `db_identifier`, `log_group_names`.
- `modules/store-pod/outputs.tf`: `cluster_name`, `nlb_arn_suffix`, `nlb_target_group_arn_suffixes`,
  `db_identifier`, `cdn_distribution_id`, `log_group_names`.
- `modules/network/outputs.tf`: `nat_gateway_id` (null unless prod-shaped).
- `modules/dashboard/`: `main.tf` (locals building sections and positions, one `aws_cloudwatch_dashboard`),
  `variables.tf`, `outputs.tf`, `versions.tf`.
- `main.tf`: `module "dashboard"` with `count = local.flavour.dashboard && !var.hibernated ? 1 : 0`.
- `outputs.tf`: `dashboard_url`.
- `README.md`: a *Dashboard* section and the layout line; `AGENTS.md` layout block.
- `qa/platform-qa.md`: cases for the page existing, every widget having data, and hibernate/wake.
- Gates: `scripts/verify.sh` (fmt, validate per root and module, tflint if installed, catalog drift).

## Other repos

None. No port, name, image, env var or SLO moves. `load-testing` may later want the dashboard URL in its
runbook once the alarms plan exists.

## Deviations, as built

- The module also outputs `body` (the rendered JSON) so the widget list can be inspected with
  `terraform output` instead of the console.
- The log widget's filter is one case-insensitive regex, `error|exception`, because Spring logs `ERROR`
  while Node and Caddy print lower-case `error` and stack traces.
- The ALB "flows" style widgets of the NLB section mix a Sum stat with an Average override on
  `ActiveFlowCount`, since an active-flow count summed over a minute is meaningless.
- Pricing of dashboards beyond the free allowance was not confirmed: the pricing MCP server was down.

## Verification

Phase 1, 2026-09-09, from the worktree:
- `scripts/verify.sh` green: fmt, init + validate for the root, prereq and all five modules, catalog
  drift against `../cvhome`. tflint and cfn-lint are not installed locally and were left to CI.
- The module was instantiated from a scratch root with sample identifiers (one pod, a NAT gateway) and
  the plan's `dashboard_body` decoded: 36 widgets, explicit non-overlapping positions, CloudFront
  widgets on `us-east-1`, percentile stats on the latency widget, the log query naming every log group.
- Orchestrator: `scripts/contract-check.py` unchanged (only pre-existing warnings); `scripts/impact.py`
  reports no contract surface.
- QA 06.1 to 06.3 are written and [not verified]: they need a live apply, which happens in CodeBuild.
