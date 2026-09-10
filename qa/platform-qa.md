# QA — platform

The path an operator takes to stand up, change, pause and tear down a CVHome environment. Terraform
`validate` and the CI `plan (dev)` comment prove the HCL; this file proves the operations end to end.

- **Scope** — the bootstrap stack, the three CodeBuild stages, promotion by tfvars, hibernate/wake, destroy.
- **Runs on** — a real AWS account and a Route53 hosted zone; eu-central-1 unless stated. Nothing here
  runs from an agent session (`AGENTS.md` → *Build, run and verify*).
- **Cases** — 24 (0 verified, 24 not verified)
- **Also see** — `../cvhome/qa/lcl-qa.md` for the stack itself, `../cvhome/store-core/*/qa/*-qa.md` for the
  product flows to run once an environment is up; `README.md` here for the commands.

Each case is tagged **[verified]** (run end to end and passed — with the date and the environment) or
**[not verified]** (never run by anyone as written down here — where the bugs are). Several of these
operations *have* happened during development (the git history is full of fixes only an apply finds), but
none was recorded against this script, so none is marked verified.

## 00 — Before you start

- An AWS account with a public hosted zone (`<domain>`) in Route53, and console access.
- A Stripe test key and its webhook signing key.
- `gh` and `terraform` (`.terraform-version`) locally for the PR-driven cases; no local AWS credentials
  are needed for anything below except reading the console.
- Names: project id `<project>` (stable, chosen by you), environment `<env>` (`dev` for all cases unless
  the case says otherwise). Resources are `${project}-${env}-*`.

## 01 — Bootstrap an environment from the launch button

### 01.1 The stack creates everything Terraform cannot create for itself [not verified]
- Setup: README → *Deploy*; the button must point at `s3://cvhome-saas/platform/bootstrap.yaml` (published
  by `publish-bootstrap.yml` on the last push to `main`).
- Steps: click the button in the target region; fill project id, env name `dev`, flavour `dev`, hosted zone,
  pod count `1`, Stripe key, product version (`latest` is allowed for dev); create the stack.
- Expect: stack `CREATE_COMPLETE`; SSM has `/<project>/dev/config`; the state bucket exists with
  versioning; the deploy role has no `PowerUserAccess` and no `iam:*`; CodeBuild projects
  `<project>-dev-{1-prereq,2-images,3-apply,hibernate,wake,destroy}` exist; secrets
  `/<project>/dev/{stripe,uaa,sso}` exist and the `sso` one holds the four client secrets and both
  remember-me keys.

### 01.2 The stack starts the pipeline by itself [not verified]
- Setup: 01.1 just completed.
- Steps: open CodeBuild → build history.
- Expect: `1-prereq` is running or done without anyone starting it.

## 02 — The three pipeline stages

### 02.1 `1-prereq` — ECR repositories and the certificate from the catalog [not verified]
- Setup: 01.2.
- Steps: wait for `1-prereq`; open ECR and ACM.
- Expect: 15 repositories, named exactly as `services.yaml` `image:` says (`store-core/uaa`,
  `store-pod/spg`, …); one ACM certificate for `<domain>` and `*.<domain>` (and the pod wildcard), status
  *Issued* after DNS validation; state at `prereq/dev/terraform.tfstate`; `2-images` started.

### 02.2 `2-images` — 15 images built from `cvhome` at the requested version [not verified]
- Setup: 02.1.
- Steps: wait for `2-images`; open the 15 repositories.
- Expect: each has the image tagged with the product version typed into the stack (`X.Y.Z`, `X.Y`,
  `latest` for a release; `latest` only for a branch build); the build log shows
  `bootBuildImage --publishImage`; the Gradle cache made the second run visibly faster; `3-apply` started.

### 02.3 `3-apply` — the environment converges and the console answers [not verified]
- Setup: 02.2.
- Steps: wait for `3-apply`; `terraform output console_url` from the build log; open it; sign in with the
  platform admin (`/<project>/dev/uaa`).
- Expect: all 15 ECS services steady (6 core, 9 per pod), circuit breaker never tripped;
  `https://console-ui.<domain>` resolves and serves the console (not `seller-ui`); the apex and `www`
  route through the gateway; a pod storefront answers on the pod domain over TLS; Cloud Map resolves
  `lb://` targets (no `UnknownHost` in service logs); the Stripe webhook is registered at
  `/billing/api/v1/stripe-webhook/public/events` and a test event reaches `billing`.

### 02.4 A failed stage stops the line [not verified]
- Setup: any environment; introduce a deliberate failure (an image path typo in `services.yaml` on a branch
  deployed to an ephemeral env).
- Steps: run `1-prereq` → observe.
- Expect: the failing stage is red and the next one does **not** start; nothing was applied on top of a
  half-built prerequisite.

## 03 — Promote by tfvars PR

### 03.1 Promote `dev` to a released version [not verified]
- Setup: a release `vX.Y.Z` exists (cut by the orchestrator, images published at that tag).
- Steps: PR changing `image_tag = "X.Y.Z"` in `envs/dev.tfvars` (the orchestrator opens it for dev); read
  the `plan (dev)` comment; merge; run `3-apply` (or let the promotion trigger it).
- Expect: the plan comment shows only task-definition changes (image tag) for the 15 services; after
  apply every task runs `<registry>/<image>:X.Y.Z`; the console reports the new version.

### 03.2 Roll back is the same PR with the previous version [not verified]
- Setup: 03.1.
- Steps: PR reverting `image_tag` to the previous version; merge; apply.
- Expect: same shape of plan; the previous images run; no data migration was needed to go back.

### 03.3 `latest` is refused for a protected flavour [not verified]
- Setup: `envs/prod.tfvars` with `image_tag = "latest"` on a branch.
- Steps: open a PR; also push a `v*` tag on a throwaway fork.
- Expect: the plan fails on the precondition in `main.tf`; the `release-guard` job fails on the tag; a
  `dev` tfvars with `latest` still passes.

## 04 — Hibernate and wake

### 04.1 Hibernate destroys the hourly things and keeps the stateful ones [not verified]
- Setup: a running `dev` (02.3) with at least one product created in the console and one media upload.
- Steps: `scripts/hibernate.sh dev` (or the `-hibernate` CodeBuild project); wait.
- Expect: ECS services, ALB, per-pod NLBs, the NAT (the instance under `dev`) and their Route53 aliases are gone; RDS instances
  are **stopped**, not deleted; S3 buckets, CloudFront distributions, secrets, ECR images, VPC, Cloud Map
  namespaces and ECS clusters remain; hostnames do not resolve; SSM `/<project>/dev/hibernated` reads
  `true`; the bill for the next hour is compute-free.

### 04.2 Wake restores everything the application can observe [not verified]
- Setup: 04.1, ideally after 8+ days (the keeper Lambda must have re-stopped RDS on day seven).
- Steps: `scripts/wake.sh dev`; wait; open the console.
- Expect: RDS started before compute (no connection errors in service logs); same RDS endpoint, same
  CloudFront domain, same hostnames; the product and the media from 04.1 are there; the media URL stored
  in the database still resolves.

### 04.3 A protected flavour refuses to hibernate [not verified]
- Setup: an environment with flavour `prod` (or `protected: true` overridden in tfvars).
- Steps: `scripts/hibernate.sh <env>`.
- Expect: refused before anything is destroyed, with a message naming the flavour.

## 05 — Destroy

### 05.1 The `-destroy` project tears the environment down completely [not verified]
- Setup: a `dev` environment nobody needs; the bootstrap stack still present.
- Steps: run `<project>-dev-destroy`; then delete the bootstrap stack.
- Expect: `terraform destroy` finishes without a manual step (the deploy role could delete the roles it
  created; SSM parameters could be deleted); the `env` and `prereq` states are empty; the stack deletes
  cleanly; nothing is left billing except what the operator chose to keep (ECR images, logs).

## 06 — Dashboard

### 06.1 The environment has one dashboard and every widget has data [not verified]
- Setup: a running `dev` (02.3) that has taken a few minutes of traffic (open the console, load a storefront
  page, upload one media file so the CDN and RDS have something to show).
- Steps: `terraform output dashboard_url`; open it in the console signed in to the account.
- Expect: a dashboard named `<project>-dev`; sections *store-core*, one per pod (`pod-507f1f77` for the
  default pod) and *network* (the NAT instance under `dev`; the NAT gateway under a flavour with
  `network.egress: nat_gateway`); every metric widget draws a
  line within five minutes (CloudFront within fifteen; its metrics arrive from us-east-1); the *Recent
  errors* table at the end of each section runs without a query error and lists ERROR lines from that
  layer's services, or nothing, which is also a pass; no widget shows "Metric not found" or an empty
  legend.

### 06.2 Hibernate removes the dashboard and wake brings it back under the same name [not verified]
- Setup: 06.1, then 04.1.
- Steps: open CloudWatch → Dashboards while hibernated; then 04.2 and reopen.
- Expect: absent while hibernated (`terraform output dashboard_url` is null); present again after wake
  under the same name, with the same sections; history for RDS continues across the gap because the
  identifiers did not change.

### 06.3 `dashboard: false` and a per-env override [not verified]
- Setup: an `ephemeral` environment, or `dev` with `flavour_overrides = { dashboard = false }` in tfvars.
- Steps: apply; open CloudWatch → Dashboards.
- Expect: no dashboard for that environment; `terraform output dashboard_url` is null; nothing else in
  the plan changed.

## 07 — Cost below prod

### 07.1 Staging runs every task on Fargate Spot [not verified]
- Setup: a running `staging` environment applied from this change (the apply redeploys every service once:
  moving a running service between capacity strategies needs a new deployment).
- Steps: `aws ecs list-tasks` / `describe-tasks` for both clusters (`<project>-staging-store-core`,
  `<project>-staging-store-pod-507f1f77`); read `capacityProviderName` on each task.
- Expect: every task says `FARGATE_SPOT`, the otel-collector included; no service was replaced (the plan
  showed in-place updates, not `-/+`); a prod plan of the same commit shows no change to any ECS service.

### 07.2 Non-prod log groups are Infrequent Access and still readable [not verified]
- Setup: a `dev` environment applied from this change (the apply replaces each service's log group:
  the class is fixed at creation), then a few minutes of traffic.
- Steps: CloudWatch → Log groups, filter `/aws/ecs/<project>/dev/`; open the dashboard's *Recent errors*
  table; run a Logs Insights query over one service's group; try `aws logs tail` on the same group.
- Expect: every group shows class *Infrequent Access*; the Insights query and the dashboard table return
  lines; `aws logs tail` is refused (the class has no GetLogEvents / FilterLogEvents), which is the known
  trade; tasks kept running while their groups were recreated; a prod plan shows no log group change.

### 07.3 Below prod, tasks leave through the NAT instance, not addresses of their own [not verified]
- Setup: a `dev` environment that ran with public task IPs, applied from this change. The cleanest path is
  `-hibernate` then `-wake`; a plain `3-apply` also works.
- Steps: read the apply log; `aws ecs describe-tasks` for a few tasks in both clusters and
  `aws ec2 describe-network-interfaces` on their ENIs; EC2 → Instances; VPC → Route tables and Endpoints;
  sign in to the console; open a storefront on the pod domain; run `scripts/register-stripe-webhook.sh`;
  put a new custom domain on a test store so Caddy asks Let's Encrypt for a certificate.
- Expect: the log shows `terraform_data.nat_ready` printing "NAT instance i-… is forwarding." before any
  ECS service is updated; no task ENI has a public IP, and every task is in a private subnet; one
  `<project>-dev-nat` t4g.nano with a public IP and source/dest check off; the private route table sends
  `0.0.0.0/0` to its ENI and has the S3 gateway endpoint; every service steady with no circuit-breaker
  rollback; console, storefront, webhook registration and the certificate all work, so image pulls,
  Secrets Manager, CloudWatch Logs, Cloud Map `DiscoverInstances`, Stripe and ACME are all getting out;
  the dashboard has a *network - NAT instance* section with data.

### 07.4 Replacing the NAT instance does not cut the environment off [not verified]
- Setup: 07.3.
- Steps: set `flavour_overrides = { network = { nat_instance_type = "t4g.micro" } }` and apply (a type
  change is a replacement: the type is rendered into the user data); keep the storefront open while it
  runs. Then remove the override and apply again.
- Expect: the plan replaces the instance (`+/-`, create before destroy) rather than updating it in place;
  the new instance is created and reports ready, the route moves to it, and only then is the old one
  terminated; service logs show no burst of connection failures to AWS APIs; tasks are not replaced.

### 07.5 The `public_ip` override puts the addresses back and removes the NAT [not verified]
- Setup: `dev` from 07.3 with `flavour_overrides = { network = { egress = "public_ip" } }` in tfvars on a branch.
- Steps: plan, then apply; revert the override and apply again.
- Expect: the first plan moves every service to the public subnets with `assign_public_ip`, destroys the
  instance, its route and the S3 endpoint, and keeps `nat_instance_type` (one-level merge); the services
  settle; the revert brings the instance back through the readiness gate. A prod plan of this commit shows
  no network change at all.

### 07.6 In dev, core and the default pod share one database [not verified]
- Setup: a `dev` environment that ran with two databases, applied from this change. The cleanest path is
  `-hibernate` (compute goes, then the pod's instance is deleted while nothing holds a connection; dev
  keeps no final snapshot) and then `-wake`. With `test_stores` on, the seed data comes back.
- Steps: RDS → Databases; read one pod service's task definition; open the core instance's security group;
  sign in to the console and load a storefront; watch the dashboard's *RDS connections* widget under
  store-core through a full redeploy (`3-apply` with a new image tag).
- Expect: one instance, `<project>-dev-store-core`, and no `…-store-pod-507f1f77`; the pod services'
  `SPRING_DATASOURCE_HOST` is the core instance and their password comes from its master secret; the core
  security group admits every core and pod service on 5432 (the pod rules say `Postgres from pod-507f1f77
  <service>`); the storefront and the console work; peak connections during the redeploy stay under 80
  (the guard's figure: eleven services × 3 × 2 = 66), with no "remaining connection slots are reserved" in
  any service log; the pod section of the dashboard has no RDS widgets of its own.

### 07.7 Other pods, staging and prod keep their own databases; the guard refuses an overflow [not verified]
- Setup: a branch with `pod_ids = ["<24 random hex>"]` in `envs/dev.tfvars`; separately,
  `flavour_overrides = { rds = { db_pool_size = 4 } }`.
- Steps: plan each; plan `staging` and `prod` from the same commit.
- Expect: the second pod plans its own `aws_db_instance`; the pool override fails at plan time with "A
  rolling deploy would open 88 connections on one db.t4g.micro, which holds about 80"; the staging plan
  keeps both instances; the prod plan shows the pod instance and security group only as `moved` to
  `[0]`, with no change to either.

## REG — regression watchlist

Defects that already shipped once in the legacy repos or during this repo's development:

- The ALB and DNS published `seller-ui.<domain>`, a host the gateway never matched (02.3).
- The Stripe webhook registered at `/subscription/api/v1/...` and the key injected into `tenancy` (02.3).
- A 512 MB task cannot start a Spring service — the buildpack needs ~680 MB of fixed regions
  (`flavours.yaml` sizes; 02.3 "all services steady").
- Security-group descriptions AWS rejects; RDS unable to reach the secrets KMS key (02.3).
- A stopped RDS that AWS restarts on day eight (04.2).
- The destroy project unable to delete the roles it created (05.1).
- Four services with no ECR repository at all (02.1: count is 15, and `check-catalog-drift.py` in CI).

## 99 — known gaps

- No automated tests (`.tftest.hcl`); static checks and plan review only, by decision.
- `plan (dev)` on a PR needs `AWS_PLAN_ROLE_ARN`, `AWS_REGION`, `PROJECT_ID` and `TF_STATE_BUCKET`
  configured on the repository; without them the job fails and the other jobs still gate the PR.
- `tflint` and `cfn-lint` are skipped by `scripts/verify.sh` when not installed locally; CI still runs
  them, so a lint failure can surface only after the push.
- `ephemeral` flavour cases (a per-branch environment) are not written yet.

### 03.x The impersonation client secret reaches uaa and the gateway [not verified]
- Setup: an environment bootstrapped (or stack-updated) with this template; cvhome ≥ 2.0.0
- Steps: update the stack (the SsoSecretsFunction adds the missing `UAA_IMPERSONATION_SECRET` key without touching existing ones); run the pipeline; in the console as super-admin, act as a merchant
- Expect: `/{project}/{env}/sso` has the key; uaa and store-core-gateway task definitions bind it; uaa starts (no unresolved `${UAA_IMPERSONATION_SECRET}`); the exchange returns 200 and `auth/me` names the merchant
