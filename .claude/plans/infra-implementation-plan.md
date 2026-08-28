# Implementing the CVHome Platform Architecture

## Context

`.claude/plans/ls-sleepy-feigenbaum.md` finished discovery: the three legacy infra repos
(`cvhome-bootstrap`, `cvhome-infra`, `cvhome-store-pod`) cannot deploy the current application. The app
ships 15 services; the Terraform knows 11, four under stale names, and six ECR repositories are missing
entirely — the image build fails before Terraform is ever reached. Nothing is deployed in AWS, so this is
greenfield: no imports, no migration, no downtime budget.

This plan turns those findings into a working `cvhome-platform` repo and a `dev` environment that actually
runs. Three decisions were taken just now and shape the sequence below:

1. **The architecture proposal document is a gate.** No HCL is written until it is approved.
2. **`cvhome-common-ecs-service` is absorbed** into this repo as `modules/ecs-service/`, not kept external
   and tag-pinned. It is where the reliability and IAM defects actually live, it needs a near-rewrite, and
   it has exactly one consumer.
3. **App-side changes in `../cvhome` are in scope.** The deployment cannot work without them.

Region for all cost figures and the first environment: **eu-central-1** (the region the legacy bootstrap
template is already published from). One-line change if wrong.

---

## Phase 1 — The proposal (gate)

**Step 1.** Write `../cvhome/.agents/plans/infra-target-architecture.md` in the structure
`../cvhome/.agents/requirments/arch.md` demands — Current State, Target Architecture, Cost Review, Build &
Rollout Plan (substituting arch.md's Migration Plan, since nothing is deployed), Architecture Decisions.

Content is the substance already worked out in `ls-sleepy-feigenbaum.md` §1–§5, with every legacy claim
anchored to a file and line. **Cost figures are deferred**: the pricing MCP server is broken in this
environment (`botocore[crt]` missing) and local AWS calls are out of scope, so §3 ships with the cost
*structure* and ranked levers but no dollar figures — none asserted from memory. ADRs cover:
ECS Fargate over EKS/App Runner; CloudFormation for bootstrap only; the service catalog; flavours; repo
consolidation (now including the `ecs-service` absorption); state and locking; per-pod RDS; per-pod NLB;
CodeBuild over Actions; networking per flavour; Spot policy. Rejected options recorded with reasons.

**Step 2.** Publish the same content as an Artifact for review.

> **Gate.** Steps 3 onward do not start until you approve the document.

---

## Phase 2 — Repo skeleton and the catalog

**Step 3.** `git init`; scaffold `.gitignore`, `.terraform-version`, `README.md`, and `versions.tf`
pinning `required_version >= 1.10` (needed for S3 native locking) and the `aws` provider to an exact
minor. Follow the `terraform-style-guide` skill for file and naming conventions throughout.

**Step 4. `services.yaml` — the single source of truth.** One entry per service:

| field | purpose |
|---|---|
| `layer` | `core` or `pod` — picks the cluster, namespace, gateway and LB |
| `port` | container port, from `common-config.yml` |
| `image` | ECR repo path, **exactly** as each `build.gradle` sets `imageName` |
| `database` | whether the service gets datasource env + secret binding |
| `health_path` | `/actuator/health` for Spring services, `/` for the UI apps |
| `edge` | `alb-host` (with hostnames), `nlb` (with ports), or `none` |
| `extra_env` | the handful of genuinely per-service keys |

Seeded from verified sources — 6 core services (`store-core-gateway` 8000, `uaa` 8001, `console-ui` 8011,
`tenancy` 8020, `billing` 8021, `pod-registry` 8022) and 9 pod services (`spg` 80, `landing-ui` 8110,
`merchant` 8120, `content` 8121, `catalog` 8122, `checkout` 8123, `cua` 8124, `payment` 8125, `inventory`
8126). Image paths are `store-core/store-core-gateway`, `store-core/uaa`, `store-core/tenancy`,
`store-core/billing`, `store-core/pod-registry`, `store-core/console-ui`, `store-pod/{spg,landing-ui,
merchant,content,catalog,checkout,cua,payment,inventory}` — 15 in total, against the legacy template's 11.

`database: true` for `uaa`, `tenancy`, `billing`, `pod-registry` (core) and `merchant`, `content`,
`catalog`, `checkout`, `payment`, `inventory`, `cua` (pod). The other four take no datasource.

**Step 5. Drift check.** `scripts/check-catalog-drift.sh` compares `services.yaml` against three app-repo
sources and exits non-zero on any mismatch:

- `store-commons/autoconfigure/src/main/resources/common-config.yml` — names and ports
- `store-commons/autoconfigure/src/main/resources/fargate-config.yml` — the `service-ports` map and the
  `eager-load.clients` list
- every `build.gradle` with `imageName = createImageName(...)` plus the three `imageGroup` UI apps —
  image paths

This is the check that would have caught all four missing services.

---

## Phase 3 — Flavours and modules

**Step 6. Flavours.** `flavours.yaml` (or a `locals` map) defining `dev`, `staging`, `prod`, `ephemeral`,
each fixing: task cpu/memory per size class, desired count, capacity-provider strategy, RDS instance class
and storage, backup retention, deletion protection, log retention, monitoring on/off, NAT gateway on/off.
Every key individually overridable from tfvars. This replaces `is_prod`, `is_monitoring`, `pod_auto_scale`
and the dead `pod_size`. `pod_size` becomes a real per-pod flavour selecting the size class.

**Step 7. `modules/ecs-service/`** — absorbed from `../cvhome-common-ecs-service` and reworked. Carry over
the task definition, Cloud Map registration (type `A`, not `SRV` — Caddy cannot use SRV) and autoscaling
policies; fix everything else:

- security group ingress on **the service's own port** from the VPC CIDR, not `0–65535`
- `capacity_provider_strategy` from the flavour: on-demand base with Spot overflow under prod, instead of
  `FARGATE_SPOT` weight 100 with no base
- `health_check_grace_period_seconds` from the flavour (Spring Boot services need a real one; currently 0)
- `deployment_circuit_breaker` enabled with `rollback = true`
- execution role scoped to the service's own ECR repo, its log group, and secrets under
  `/${project}/${env}/*` — replacing `s3:*`, `ssm:*`, `secretsmanager:*` on `*`
- `retention_in_days` from the flavour rather than hardcoded 14
- delete the never-consumed inputs: `priority`, `service_type`, `load_balancer_host_matchers`, and
  `health_check` unless a target group actually reads it

**Step 8. `modules/network/`** — VPC, three subnet tiers, the log bucket. NAT gateway and private task
placement gated on the flavour: prod runs tasks in private subnets behind one NAT; dev/staging keep public
subnets (NAT at ~$33/mo/AZ is not worth it there, and interface endpoints are not cheaper). RDS never
`publicly_accessible`.

**Step 9. `modules/store-core/`** — ECS cluster, Cloud Map namespace, ALB, RDS, and services generated by
`for_each` over the `core` slice of the catalog. Common env computed once into a `local` and merged with
`extra_env`, replacing the copy-paste blocks. Specifically:

- ALB host rules and Route53 records derive from the catalog — so the rule is `console-ui.<domain>`,
  matching `GatewayRouteLocatorImpl`, and the `seller-ui` record disappears
- RDS-managed master user secret; datasource env injected only for `database: true` services
- **one** otel-collector per environment, in the core namespace, gated on the flavour

**Step 10. `modules/store-pod/`** — per-pod cluster, namespace, NLB, RDS, CDN bucket + CloudFront, cert
bucket, and pod services by `for_each`. `spg` keeps its three ports (80, 443, 2019) and the NLB health
check on 2019's `/config/`. Pod services point at the environment-level collector across namespaces —
same VPC, so `otel-collector.<core-namespace>` resolves.

---

## Phase 4 — Root configuration and state

**Step 11.** Root `main.tf` / `variables.tf` / `outputs.tf` / `backend.tf`. State at
`env/<env>/terraform.tfstate` with `use_lockfile = true` — no DynamoDB table. Resources named
`${project}-${env}-*`, with `project` a stable settable id and `env` a first-class variable. Config
layering: read the SSM record bootstrap wrote, overlay `envs/<env>.tfvars`, **tfvars wins**.

**Step 12.** `prereq/` — a small second root holding ECR repositories and the ACM certificate, both
`for_each`ed from the same catalog. Applied before the image build; the `env` root runs after.

---

## Phase 5 — Bootstrap

**Step 13. `bootstrap/bootstrap.yaml`.** Parameters: hosted zone, **env name**, flavour, project id, pod
count, pod size, Stripe key, GitHub account/branch. Creates only what Terraform cannot create for itself —
state bucket, scoped deploy role, CodeBuild projects — writes the config record to
`/${project}/${env}/config`, **and then starts the pipeline** via a custom resource. Nothing triggers
CodeBuild in the legacy template, which is why its one-click deploy stops halfway.

CodeBuild projects: `prereq-apply` → `image-build` → `env-apply`, plus `destroy`. The deploy role drops
`PowerUserAccess` + `iam:*` for an explicit statement list. Validate with
`validate_cloudformation_template` and `check_cloudformation_template_compliance` before calling it done.

**Step 14. Stripe webhook init.** Rebuild the lambda to register
`/billing/api/v1/stripe-webhook/public/events` — the legacy template registers
`/subscription/api/v1/stripe-webhook/public/events`, a path that did not survive the tenancy/billing
split. Secret lands under `/${project}/${env}/stripe` and binds to **`billing`**, not `tenancy`.

---

## Phase 6 — CI/CD

**Step 15. `.github/workflows/terraform-validate.yml`** — the validation pipeline, on every push and PR:

| Job | Runs | Fails on |
|---|---|---|
| `fmt` | `terraform fmt -check -recursive` | any unformatted file |
| `validate` | `terraform init -backend=false` + `validate`, each root **and** each module | invalid HCL, bad references |
| `lint` | `tflint --recursive` with the AWS ruleset | deprecated syntax, bad instance types, unused declarations |
| `catalog-drift` | `scripts/check-catalog-drift.sh` | `services.yaml` disagrees with the app repo |
| `cfn` | `cfn-lint` + `cfn-guard` on `bootstrap/bootstrap.yaml` | template or policy violations |
| `plan` | `terraform plan` against `envs/dev.tfvars`, posted as a PR comment | — informational |

The first five jobs need **no AWS credentials**, so they run on forks too; only `plan` assumes a role, via
**OIDC**. No static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` anywhere. Apply stays with CodeBuild —
this workflow replaces `cvhome-infra`'s `trigger-apply.yml`, and Actions never applies again.

> **Tests deferred by decision.** No `.tftest.hcl` for now. The catalog drift check plus plan review carry
> that weight until the modules settle.

---

## Phase 7 — Application repo (`../cvhome`)

**Step 16.** `store-commons/autoconfigure/src/main/resources/fargate-config.yml` — remove the pinned
`namespace: store-pod-507f1f77.cvhome.lcl` and `namespace-id: ns-je7qri6wn7fbsrpn` defaults; both become
environment-supplied, matching what Terraform already injects as
`SPRING_CLOUD_ECS_DISCOVERY_NAMESPACE{,-ID}`.

**Step 17.** `.github/workflows/trigger-publishing-to-private-ecr.yml` and
`on-tag-publishing-to-private-ecr.yml` — replace the `cksum(account-owner-region)` project id with the
real one read from SSM, and swap static credentials for OIDC. Today these push images to a registry path
Terraform never looks at.

---

## Phase 8 — Stand up and validate

**Step 18.** Launch the bootstrap into eu-central-1 with flavour `dev`, then verify each stage
independently: SSM config record written → prereq apply creates 15 ECR repos and the certificate → image
build pushes 15 images → env apply converges → all services steady in ECS.

**Step 19.** Validate against the app's real QA path (`../cvhome/qa/`): sign in to the console at
`console-ui.<domain>`, load a storefront on the pod domain, confirm Cloud Map discovery resolves
`lb://` targets, and confirm a Stripe webhook delivery reaches `billing`.

**Step 20.** Add `staging` and `prod` flavours; confirm prod moves tasks to private subnets, flips
capacity to on-demand base, and enables RDS backups, encryption and deletion protection.

**Step 21.** Archive `cvhome-bootstrap`, `cvhome-infra`, `cvhome-store-pod`, `cvhome-common-ecs-service`;
delete `cvhome-secrets` (read by nothing, and its `bcrypt()` locals re-hash every plan).

---

## Verification

- **Catalog drift**: `scripts/check-catalog-drift.sh` exits 0 against the current `../cvhome` checkout.
- **Static**: `terraform fmt -check`, `terraform validate`, `tflint` clean on every root and module;
  `cfn-lint` and `cfn-guard` clean on `bootstrap.yaml`.
- **Plan review** (in place of automated tests, deferred): `terraform plan` against `envs/dev.tfvars`
  shows 15 services with the right ports and image paths, and no datasource env on the four services the
  catalog marks `database: false`.
- **Line count**: the pod service definitions come in near ~150 lines against the legacy 654, and adding a
  service is a single catalog entry.
- **Dead inputs**: every declared variable is referenced — grep each `variable` block for a use.
- **End to end**: Step 18's staged bootstrap, then Step 19's QA path against a live `dev`.

## Constraints in force

- **eu-central-1** for the first environment and all cost work. Say the word if it should be elsewhere.
- **No local AWS calls.** Pricing figures stay deferred; nothing runs against a live account from here.
- **No automated tests for now.** Static checks and plan review only.
