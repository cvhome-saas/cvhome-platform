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

## Other repos

None. No port, image, environment variable name or SLO changes. cvhome already runs core and pod services
on one database under lcl.

## Deviations, as built

(filled in while implementing)

## Verification

(filled in while implementing)
