# Non-prod cost: private tasks behind a NAT instance, Spot-only staging, one database in dev

## Context

Below prod, environments pay for things nobody chose:

- **A public IPv4 address per task.** `flavours.yaml` sets `private_tasks: false` for dev, staging and
  ephemeral, so `modules/network/outputs.tf` hands every ECS service a public subnet and
  `assign_public_ip = true`. AWS bills every public IPv4 at $0.005/h (us-east-1), in use or idle. Dev runs
  15 tasks, staging 16 (with the collector): **$54.75 and $58.40 a month** in addresses alone. The
  architecture doc's "no NAT below prod" (§h, ADR-10, cost review) was written without that charge; a
  t4g.nano NAT instance with one public address is about $7.40 a month.
- **Staging is on-demand in practice.** `capacity.on_demand_base: 1` is per service, and every staging
  service runs one task, so all 16 tasks are on-demand Fargate: 5.75 vCPU and 16 GB, **$221.83 a month**
  at $0.04048/vCPU-h and $0.004445/GB-h. Fargate Spot is up to 70% off.
- **Two databases where one will do.** Each layer creates its own RDS instance
  (`modules/store-core/rds.tf`, `modules/store-pod/rds.tf`). Every service owns a schema named after itself
  (`hikari.schema: ${spring.application.name}` in cvhome's `common-config.yml`) and lcl already runs all 15
  services on one database, so core and one pod fit on one instance. Dev pays $27.96 a month for two
  db.t4g.micro instances and their storage; one is $13.98.
- **Standard-class log ingestion** at $0.50/GB where the Infrequent Access class costs $0.25/GB.

Prices are us-east-1 list prices from the public price-list files
(`pricing.us-east-1.amazonaws.com/offers/v1.0/aws/{AmazonECS,AmazonVPC,AmazonRDS,AWSELB,AmazonCloudWatch,AmazonEC2}`),
730 hours a month.

## Why the design is what it is

- **Prod does not move.** Every change is a flavour key whose prod value reproduces today's resources at
  their current addresses. A prod plan is `0 to add, 0 to change, 0 to destroy`, with `moved` notes and a
  changed `flavour` output only.
- **Egress is one choice, not two booleans.** `private_tasks` + `nat_gateway` had one invalid combination
  guarded by a precondition. `network.egress = public_ip | nat_instance | nat_gateway` has none, and a third
  mode fits without a fourth boolean.
- **A NAT instance, not interface endpoints.** Tasks need ECR, Secrets Manager, CloudWatch Logs, Cloud Map
  `DiscoverInstances`, Stripe and ACME. Interface endpoints are $0.01/h each per AZ and still leave Stripe
  and ACME needing a NAT. The free S3 gateway endpoint is added in `nat_instance` mode so image layers (which
  ECR serves from S3) bypass the instance.
- **The AWS-documented NAT recipe on an AWS-owned AMI.** AL2023 arm64 and the steps from the VPC guide
  ("Create a NAT AMI"), not a community NAT image. No instance profile and no SSH key: the bootstrap's
  deploy role cannot create instance profiles, and the instance needs none.
- **A readiness gate.** Services moved into private subnets before the instance forwards packets would fail
  their image pulls and trip the circuit breaker. The user data prints a marker to the console last;
  `terraform_data.nat_ready` polls `ec2:GetConsoleOutput` for it, and the private route waits on it.
- **The default pod shares, other pods do not.** A second pod's services would collide with the first
  pod's schema names on one database. Sharing is `rds.shared` in dev and ephemeral only; staging keeps
  prod's per-pod topology and its data.
- **Staging accepts Spot.** A reclaim at desired 1 is a short outage of one service, and ECS does not fall
  back to on-demand when Spot capacity is short. `flavour_overrides.capacity.on_demand_base = 1` puts it back.
- **Not done:** compute in one AZ (about $3.65 per pod a month for one NLB address, and it would replace
  the NLBs), EC2 hosts packing the services (a 16 GB r7g.large is $78.18 a month on-demand against roughly
  $58 of Fargate Spot for the same 5 vCPU / 14 GB), scheduled hibernation, a `terraform test` suite.

## Phase 1 — staging on Fargate Spot only (commit 1)

`flavours.yaml` staging `capacity.on_demand_base: 0`. `modules/ecs-service` gains `force_new_deployment`,
rendered `true` or `null`, passed as `!flavour.protected`: provider 6.62.0 refuses a
`capacity_provider_strategy` change without it, and `null` leaves prod's services untouched.

## Phase 2 — Infrequent Access log groups below prod (commit 2)

Flavour key `log_class` (`INFREQUENT_ACCESS` below prod, `STANDARD` in prod) into the `log_group_class`
of every service's log group. ForceNew: non-prod log groups are recreated. Logs Insights and the dashboard's
error table keep working; Live Tail, `aws logs tail` and the ECS console log tab do not.

## Phase 3 — egress as a flavour choice, NAT instance below prod (commit 3)

`network: { egress, nat_instance_type }` replaces `private_tasks` / `nat_gateway`. `modules/network` keeps
the gateway resources at their addresses, adds the NAT instance, its security group, the readiness gate and
the S3 gateway endpoint, and routes `0.0.0.0/0` through one `aws_route.private_nat` whose target is the
gateway or the instance's primary ENI. Outputs that place tasks depend on the route. The dashboard gains an
EC2 section for the instance. CI validates `modules/dashboard`, which it did not.

## Phase 4 — dev and ephemeral share one database (commit 4)

`rds.shared` in the flavour. store-core exports its database; the default pod takes it instead of creating
one (`count` on the pod's instance and security group, with `moved` blocks); its services get ingress on
core's security group. A root precondition keeps the pools of every service on one instance, doubled for a
rolling deploy, under the class's connection limit. The dashboard skips a sharing pod's RDS widgets.

## Phase 5 — prod plans again (commit 5)

Found while verifying phase 3 and added at the user's request. `main.tf` and `prereq/main.tf` derived
`dns_prefix = coalesce(var.dns_prefix, var.env == "prod" ? "" : var.env)`. `coalesce` skips empty strings
as well as nulls, so prod's `""` was never returned and every prod plan failed in both roots with "no
non-null, non-empty-string arguments". An explicit `dns_prefix = ""` below prod was also replaced by the
environment name. Both roots now use a plain null check. Nothing changes for an environment that planned
before: the value is the same wherever `coalesce` returned one.

## Other repos

None. No port, image, environment variable name or SLO changes. cvhome already runs core and pod services
on one database under lcl.

## Deviations, as built

- **The NAT image follows the instance type.** `data "aws_ec2_instance_type"` picks arm64 or x86_64 for the
  AL2023 image, instead of refusing non-Graviton types.
- **A type change replaces the NAT instance.** The type is rendered into the user data, so changing
  `nat_instance_type` goes through create-before-destroy and the readiness gate. Without that it would be an
  in-place stop and start: every task cut off, or a failure across architectures, since `ami` is ignored after
  creation.
- **The readiness gate waits up to ten minutes, not five.** A failed gate stops the apply, so it errs long.
- **The connection guard covers every flavour's busiest instance, not only shared ones.** Staging comes to 84
  of 190 and prod to 168 of 190, so both pass.
- **The QA file's case count was stale.** It said 15 while 17 cases existed; it now counts 24.
- **Found while verifying:**
  - `main.tf:60` and `prereq/main.tf:37` derived `dns_prefix` with `coalesce()`, so no prod plan could
    succeed (introduced in a2a4972). **Fixed in phase 5**, at the user's request, in this same PR.
  - Not fixed (pre-existing): on a first create under prod, `aws_appautoscaling_policy.requests` has a
    `count` that depends on the new ALB's ARN suffix, which is unknown at plan time. A fresh prod
    environment cannot plan; an existing one can, because its suffix is in state.
- **Unchanged:** `bootstrap/bootstrap.yaml`'s flavour description, which is still true for prod ("prod runs
  tasks in private subnets behind a NAT gateway"). Leaving it avoids republishing the template for wording.

## Verification

- **`scripts/verify.sh` passes:** fmt; init and validate for the root, `prereq` and all five modules; catalog
  drift ("no drift"). tflint and cfn-lint are not installed locally.
- **tflint 0.64.0**, the `latest` CI installs, run in its container against the worktree mounted read-only,
  with the aws ruleset 0.44.0 from `.tflint.hcl`: no issues. The bootstrap is untouched, so cfn-lint is not needed.
- **A scratch mocked plan** (`terraform test` with `mock_provider "aws"` and `command = plan`, in a copy
  outside the repo, not committed) passes all eight runs:

  | Run | What it asserts |
  |---|---|
  | dev | one NAT instance, security group, S3 endpoint, readiness gate and route; no gateway; no public task IPs |
  | dev hibernated | instance and route gone; security group and endpoint kept |
  | dev with `network = { egress = "public_ip" }` | no NAT at all; public tasks; `nat_instance_type` survives the one-level merge |
  | prod | gateway, EIP and route only; nothing new; private tasks |
  | dev with a second pod | pod-1 shares (no instance or security group of its own), pod-2 keeps its own; 66 of 80 |
  | dev with `db_pool_size = 4` | the guard fails the plan (88 > 80) |
  | staging | its own pod database, behind the NAT instance; 84 of 190 |
  | prod database | its own pod database; 168 of 190 |

  After phase 5 all eight pass against the committed code, and the prod run also asserts that prod owns the
  bare apex. The one scratch-only patch left drops prod's `request_target`, for the first-create `count`
  issue above.
- **Phase 5, the `prereq` root under the same kind of mocked plan:**
  - prod owns the bare apex (`dns_prefix = ""`, `app_domain` is the zone).
  - dev sits under `dev.`.
  - An explicit `dns_prefix = ""` is honoured.

  Against `origin/main`'s `prereq/main.tf` the prod run fails with the `coalesce` error; against this branch
  all three pass.
- **User data rendered** with sample values: no interpolation left, `bash -n` clean.
- **The readiness gate's loop,** run against a stub `aws`: marker on the third poll gives exit 0; never
  gives exit 1 with the message.
- **`scripts/contract-check.py --cvhome-platform <worktree>`:** catalog, env and edges OK. The WARNs (spg image
  pins, `image_tag = latest`, QA counts) predate this change. `scripts/impact.py`: no env name, health check,
  TLS or bucket contract changes.
- **Not run:** any real plan or apply. There are no AWS calls from an agent session, and `plan (dev)` is
  skipped in this repo's CI. QA 07.1–07.7 are **[not verified]** until an operator runs them.
