# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Orientation

`cvhome-platform` is the **new, consolidated infrastructure repo for CVHome** — a multi-tenant e-commerce
SaaS (Java 25 / Spring Boot services + Angular/Next.js frontends) that runs on **ECS Fargate + Cloud Map**.

**The repo is currently empty.** It holds no Terraform, no CloudFormation, no code — only installed skills
and the approved architecture plan. Every path in *Target layout* below is something to be created, not
something to read. It is also **not yet a git repository** (`git init` before the first commit).

**Nothing is deployed in AWS.** The three legacy infra repos are unprovisioned dead code. There is no
migration, no state to import, no downtime budget, no backward compatibility to preserve. Design and build
on the merits.

## Read these before making architecture decisions

| What | Where |
|---|---|
| **The approved plan** — decisions, design rules, deliverables | `.claude/plans/ls-sleepy-feigenbaum.md` |
| The original requirements (priorities, expected output) | `../cvhome/.agents/requirments/arch.md` |
| The application repo, and its own agent rules | `../cvhome/`, `../cvhome/AGENTS.md` |
| **Service catalog — source of truth for names & ports** | `../cvhome/store-commons/autoconfigure/src/main/resources/common-config.yml` |

Legacy repos, for reference only — being replaced, never extended:
`../cvhome-bootstrap` (CloudFormation, 1275 lines) · `../cvhome-infra` · `../cvhome-store-pod` ·
`../cvhome-secrets` (dropped entirely). `../cvhome-common-ecs-service` **survives** as an external module
repo, but must be consumed **tag-pinned**, never `?ref=main`.

The proposal document the plan calls for (`../cvhome/.agents/plans/infra-target-architecture.md`) has
**not** been written yet. Check whether it exists before assuming approval to implement.

## The 15 services this infrastructure deploys

Read from `common-config.yml`; keep `services.yaml` in sync with it.

**store-core** (namespace `store-core.*`, fronted by ALB, gateway `store-core-gateway`):
`store-core-gateway` 8000 · `uaa` 8001 · `console-ui` 8011 · `tenancy` 8020 · `billing` 8021 ·
`pod-registry` 8022

**store-pod** (per-pod namespace, fronted by NLB, gateway `spg`):
`spg` 80 · `landing-ui` 8110 · `merchant` 8120 · `content` 8121 · `catalog` 8122 · `checkout` 8123 ·
`cua` 8124 · `payment` 8125 · `inventory` 8126

The legacy Terraform knows only 11 of these, four under stale names (`control-plane`→`tenancy`,
`seller-ui`:8010→`console-ui`:8011), and is missing `billing`, `pod-registry`, `content`, `inventory` plus
their ECR repositories. **Do not copy service lists out of the legacy code.**

## Locked-in decisions

These were decided with the user. Don't relitigate them; raise a concern only if you find hard evidence
against one.

1. **ECS Fargate + Cloud Map stays.** The app is ECS-native (`ecs-service-discoveryclient` resolves `lb://`
   through Cloud Map `DiscoverInstances`; there is a `fargate` Spring profile). EKS and App Runner were
   rejected — recorded as a decision record, not an assumption.
2. **One repo** replaces bootstrap + infra + store-pod. `cvhome-common-ecs-service` stays external and
   tag-pinned; `cvhome-secrets` is deleted.
3. **`services.yaml` is the single source of truth.** Terraform `for_each`es it into ECR repos, ECS
   services, task definitions, env vars, hostnames, routes and secret bindings. Common env computed once
   into a `local`. CI diffs it against the app's `common-config.yml` and fails on drift.
4. **Flavours** (`dev`, `staging`, `prod`, `ephemeral`) replace the scattered `is_prod` / `is_monitoring` /
   `pod_auto_scale` / `pod_size` flags — one named bundle fixing CPU/memory, desired count, Spot policy,
   RDS class, backups, log retention, monitoring; each key individually overridable.
5. **Two-step deploy.** Step 1: CloudFormation bootstrap (one click) collects inputs, writes the env config
   to SSM, creates only what Terraform can't create for itself (state bucket, deploy role, CodeBuild
   projects), then **starts the pipeline**. Step 2: Terraform via CodeBuild — `prereq` state (ECR + ACM
   from the catalog) → image build → `env` state.
6. **CodeBuild is the canonical deployer.** GitHub Actions drops to plan-on-PR via **OIDC** (no static
   `AWS_ACCESS_KEY_ID` secrets).
7. **Per-pod RDS** and **per-pod NLB**. Isolation over cost; `spg` terminates TLS with Caddy on-demand
   certificates for custom tenant domains, which SNI routing on a shared NLB cannot express.
8. **`project` is a stable, settable id** (not random 4 chars) and **`env` is a real parameter**. Resources
   named `${project}-${env}-*`. State at `env/<env>/terraform.tfstate` with **S3 native locking**
   (`use_lockfile`, Terraform ≥ 1.10) — no DynamoDB table.
9. Config layering: SSM holds what bootstrap generates, `envs/<env>.tfvars` holds what humans choose,
   **tfvars wins**.

## Target layout

```
bootstrap/bootstrap.yaml          # step 1, CloudFormation
services.yaml                     # the catalog
modules/{store-core,store-pod,network}/
envs/{dev,staging,prod}.tfvars
main.tf variables.tf outputs.tf backend.tf
```

## Design rules — each answers a specific legacy defect

- **One catalog, machine-read, drift-checked in CI.** Four services shipped with no infrastructure at all
  because the list was hand-maintained.
- **No copy-paste env vars.** `store-pod-cluster.tf` is 654 lines because ~25 identical env vars were
  pasted into six service blocks. The replacement should be ~150.
- **One deployer, one project id, resolved from one place.** The legacy bootstrap derives `project` as a
  random 4-char id while the GitHub Actions workflows derive it as `cksum(account-owner-region)` — so the
  app's publish workflow pushes images where Terraform never looks.
- **Every input is consumed or absent.** `pod_size`, `private_subnets`, `random_password.password`,
  `health_check`, `priority`, `service_type`, `load_balancer_host_matchers` are all threaded through the
  legacy code and never read. Don't declare a variable you don't use.
- **Pin by tag.** `git::…?ref=main` module sources mean an apply can change behaviour with no commit.
- **Secure by default, not retrofitted.** Per-service security groups on the service's own port (not
  0–65535); RDS not publicly accessible; task IAM scoped to real ARNs (the legacy roles hold `s3:*`,
  `ssm:*`, `secretsmanager:*` on `*`, and the deploy role has `PowerUserAccess` **and** `iam:*`).
- **Reliable by default.** On-demand Fargate base with Spot overflow under prod (legacy is
  `FARGATE_SPOT` weight 100, no base); deployment circuit breaker with rollback; a real
  `health_check_grace_period_seconds` for Spring Boot; RDS encryption, backups, deletion protection under
  prod. Private subnets + a single NAT gateway **only** under the prod flavour — NAT at ~$33/mo/AZ is not
  worth it in dev/staging.
- **Right-size.** All 15 services are currently identically 512 CPU / 1024 MB / 1 task — the largest easy
  cost win.

## Working rules

- **Verify claims against files.** Every statement about the legacy code in the plan is anchored to a file
  and line because it was read, not inferred. Hold new claims to the same bar.
- **Cost figures come from the AWS pricing tooling** (`mcp__plugin_deploy-on-aws_awspricing__*`), never
  from memory, and are stated as list price for one named region.
- **Use the installed Terraform skills** before writing HCL: `terraform-style-guide` (formatting and naming
  conventions), `terraform-test` (`.tftest.hcl`), `terraform-stacks`, `terraform-policy`,
  `terraform-search-import`. For CloudFormation, use the `aws-cloudformation` skill and validate with
  `validate_cloudformation_template` / `check_cloudformation_template_compliance` before proposing a
  template as done.
- **App-side changes belong to `../cvhome`, not here** — but the target architecture requires them: the
  stale `fargate-config.yml` defaults (`namespace-id: ns-je7qri6wn7fbsrpn`, namespace
  `store-pod-507f1f77`) must become environment-supplied, and the publish workflow must resolve the real
  project id from SSM. Flag them; don't silently skip them.
- Known routing bugs to get right from the catalog rather than reproduce: the ALB rule and Route53 record
  say `seller-ui.<domain>` while `GatewayRouteLocatorImpl` only accepts `console-ui.<domain>`; the Stripe
  webhook is registered at `/subscription/api/v1/stripe-webhook/public/events` but the real path is
  `/billing/api/v1/stripe-webhook/…`, and the Stripe key is injected into `tenancy` though Stripe now lives
  in `billing`.
