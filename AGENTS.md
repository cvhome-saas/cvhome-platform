# AGENTS.md

Guidance for AI coding agents working in `cvhome-platform`. It applies to the whole repository.

## Orientation

`cvhome-platform` is the **consolidated infrastructure repo for CVHome** — a multi-tenant e-commerce SaaS
(Java 25 / Spring Boot services + Angular/Next.js frontends, the `../cvhome` repo) that runs on **ECS
Fargate + Cloud Map**. It replaced `cvhome-bootstrap`, `cvhome-infra`, `cvhome-store-pod` and
`cvhome-common-ecs-service`; the last one was **absorbed as `modules/ecs-service/`** rather than kept
external, because that is where the reliability and IAM defects lived and it had exactly one consumer.

**The repo is built and applied.** About 5k lines of Terraform, one CloudFormation template and a few
scripts, on `main`, with a history of fixes that only a real apply finds (rejected SG descriptions, the JVM
memory floor, connection-pool sizing, secret bindings). The architecture proposal it implements is
`docs/infra-target-architecture.html` (approved; the markdown twin lives in
`../cvhome/.agents/plans/infra-target-architecture.md`), and `.claude/plans/infra-implementation-plan.md`
is the plan it was built from, phase by phase. Whether an environment is *up right now* is a question for
the AWS console, not this file.

What exists, and where:

```
bootstrap/bootstrap.yaml   step 1 — the only CloudFormation left; guard rules in bootstrap/guard-rules
services.yaml              the catalog: 15 services, for_each'd into everything
flavours.yaml              environment shapes (dev, staging, prod, ephemeral) and the size table
prereq/                    ECR + ACM, its own state, applied before the image build
modules/ecs-service/       one ECS service: task def, SG, Cloud Map, IAM, autoscaling
modules/network/           VPC, subnets, the NAT: gateway (prod) or instance (below prod)
modules/store-core/        cluster, ALB, RDS, the 6 core services
modules/store-pod/         per pod: cluster, NLB, RDS, CDN, the 9 pod services
modules/dashboard/         one CloudWatch dashboard per environment from the default AWS metrics
envs/*.tfvars              human choices per environment (image_tag = the product version it runs)
scripts/                   check-catalog-drift.py, check-release-pins.py, hibernate.sh, wake.sh,
                           register-stripe-webhook.sh, verify.sh + verify.steps.sh
main.tf variables.tf outputs.tf backend.tf versions.tf   the environment root
```

**The pipeline.** The README's launch button creates the bootstrap stack; it writes the env config to SSM,
creates the state bucket, a scoped deploy role and the CodeBuild projects, then starts the line:
`1-prereq` (ECR + ACM from the catalog) → `2-images` (`bootBuildImage --publishImage -Pversion=$IMAGE_TAG`
in `../cvhome`) → `3-apply` (`terraform apply`). Each stage starts the next only on success. Companion
projects: `-hibernate`, `-wake` (`scripts/hibernate.sh` / `wake.sh` do the same from a laptop) and
`-destroy`. **CodeBuild is the deployer; GitHub Actions only validates**
(`.github/workflows/terraform-validate.yml`: fmt, validate per root and module, tflint, catalog drift,
cfn-lint + cfn-guard, a `plan (dev)` comment on same-repo PRs via OIDC, and `release-guard` on `v*` tags).
`publish-bootstrap.yml` uploads the template to S3 on push to `main` so the button points at something real.

**The drift check.** `services.yaml` is the single source of truth and `scripts/check-catalog-drift.py`
compares it against three sources in `../cvhome` (`common-config.yml`, `fargate-config.yml`, every
`build.gradle` image name); CI fails on any mismatch and picks the application branch by name, or the tag
pair on a release. This is the check that would have caught the four services the legacy stack never knew.

**Fixed, not to be reintroduced.** The three legacy routing defects are gone: the ALB and Route53 publish
`console-ui.<domain>` (the host the gateway actually matches; `services.yaml` → `store-core-gateway.edge`),
the Stripe webhook is registered at `/billing/api/v1/stripe-webhook/public/events`
(`scripts/register-stripe-webhook.sh`), and the Stripe secret is bound to `billing`, not `tenancy`. The
app-side prerequisites landed too: `fargate-config.yml` no longer pins a namespace id, and the image build
runs here at the tag. *Working rules* below still lists them so a rewrite does not undo them.

**Versions.** This repo has no version of its own and no version file. The orchestrator
(`cvhome-saas/orchestrator`, `Release` workflow) tags it `vX.Y.Z` in lockstep with `cvhome`; what an
environment *runs* is `image_tag` in `envs/<env>.tfvars`, promoted by PR. Details and the `latest` rules:
README → *Versions and promotion*.

## Read these before making architecture decisions

| What | Where |
|---|---|
| How to deploy, hibernate, promote; the layout | `README.md` |
| **The approved architecture** — decisions, cost structure, ADRs | `docs/infra-target-architecture.html` |
| The implementation plan, as built | `.claude/plans/infra-implementation-plan.md` |
| The discovery notes behind it (historical) | `.claude/plans/ls-sleepy-feigenbaum.md` |
| The application repo, and its own agent rules | `../cvhome/`, `../cvhome/AGENTS.md` |
| **Service names & ports — what the catalog is checked against** | `../cvhome/store-commons/autoconfigure/src/main/resources/common-config.yml` |

The legacy repos (`cvhome-bootstrap`, `cvhome-infra`, `cvhome-store-pod`, `cvhome-common-ecs-service`,
`cvhome-secrets`) are replaced and archived. Read them for archaeology only; **never copy a service list,
an IAM policy or a module source out of them.**

## The 15 services this infrastructure deploys

`services.yaml` is the catalog; `common-config.yml` in the app is what CI checks it against.

**store-core** (namespace `store-core.*`, fronted by ALB, gateway `store-core-gateway`):
`store-core-gateway` 8000 · `uaa` 8001 · `console-ui` 8011 · `tenancy` 8020 · `billing` 8021 ·
`pod-registry` 8022

**store-pod** (per-pod namespace, fronted by NLB, gateway `spg`):
`spg` 80 · `landing-ui` 8110 · `merchant` 8120 · `content` 8121 · `catalog` 8122 · `checkout` 8123 ·
`cua` 8124 · `payment` 8125 · `inventory` 8126

Adding a service is one catalog entry plus the app-side registration `../cvhome/AGENTS.md` demands; the
drift check will not let either side land alone.

## Working conventions (org standard — the same in every cvhome-saas repo)

- **`main` is the integration branch.** Every change lands by PR into `main`; nobody commits or pushes to
  `main` directly. Versions are `vX.Y.Z` git tags cut by the orchestrator's `Release` workflow, never by hand,
  and no file in this repo carries a version.
- **Every change starts as a fresh worktree cut from up-to-date `main`, before the first file is written:**

  ```bash
  git fetch origin
  git worktree add --no-track .claude/worktrees/<type>-<short-name> -b <type>/<short-name> origin/main
  ```

  `<type>` ∈ `feat|fix|docs|chore|refactor|test`. Work, build and verify from inside that worktree; the
  primary checkout stays clean on `main`. `.claude/hooks/worktree-guard.mjs` denies any edit in the primary
  checkout (`ALLOW_MAIN_WRITES=1` is the person's deliberate escape hatch, never the agent's).
- **A plan is phases; a phase is one PR.** Anything bigger than one PR starts as
  `.agents/plans/<kebab-name>.md` (template: `.agents/plans/README.md`): context, why the design is what it
  is, then `## Phase N — <area> (PR N)` sections each small enough to review in one sitting, then
  deviations as built and verification. One plan, one worktree, one branch; each phase is committed and
  shipped as its own PR before the next begins (stacked if it must). A plan that touches another repo names
  it and hands that phase to the orchestrator (`cross-repo-change`). `.claude/plans/` holds the plans
  written before this convention; new ones go in `.agents/plans/`.
- **Nothing is pushed until the gates have passed locally.** `scripts/verify.sh` runs exactly what CI runs
  (`scripts/verify.steps.sh`) and writes a receipt for the exact tree; `.githooks/pre-push` and
  `.claude/hooks/push-guard.mjs` refuse a push without it, a push to `main`, and `--no-verify`.
- **`/go` ships the working tree** (commit → verify → push → PR into `main`, template filled, changelog
  label); **`/reset` returns to a clean `main`** without losing work. Both in `.claude/commands/`.
- **PR body follows `.github/PULL_REQUEST_TEMPLATE.md`**: *Why → What → The parts that are not obvious →
  Deviations → Verification*. Label it: `type/enhancement|bug|documentation|test|chore|dependency-upgrade`,
  `warn/api-change|behavior-change|deprecation|regression|blocker`, `ignore-changelog`.
  `.github/release.yml` turns labels into release notes; the orchestrator turns them into the version bump.
- **QA is a file that travels with the code.** An operator-visible behaviour — a pipeline stage, a
  promotion, hibernate/wake, a destroy — is not done until it has a case in `qa/platform-qa.md` (template:
  `qa/README.md`), tagged **[verified]** / **[not verified]**, with setup, steps and expected result.
  `terraform validate` proves the HCL parses; the QA file proves the path an operator takes.
- **Commit messages**: `<type|area>: <what changed>`, imperative, plus a body when the change is not
  self-evident, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Build, run and verify

```bash
scripts/verify.sh                                   # every gate below, then the push receipt
terraform fmt -recursive -check                     # CI `format`
terraform -chdir=<dir> init -backend=false -input=false && terraform -chdir=<dir> validate
                                                    # CI `validate`, for . prereq modules/*
tflint --init && tflint --recursive --minimum-failure-severity=warning   # CI `lint` (skipped locally if absent)
python3 scripts/check-catalog-drift.py --app-repo ../cvhome              # CI `catalog drift`
cfn-lint bootstrap/bootstrap.yaml                   # CI `cloudformation` (skipped locally if absent; cfn-guard is CI-only)
```

What binds every change:

- `.terraform-version` pins Terraform (`1.14.6`, the same as `TF_VERSION` in the workflow); validation
  must never need a state bucket or credentials (`-backend=false`).
- **No local AWS calls from an agent session** — plans and applies happen in CI and CodeBuild.
- A catalog change is a two-repo change; the drift check picks the app branch by *name*, so use the same
  branch name in `../cvhome` (`cross-repo-change` in the orchestrator).

## Completion gates

- [ ] `scripts/verify.sh` green for the exact tree being pushed
- [ ] `qa/platform-qa.md` has a case for any operator-visible behaviour that changed, tagged honestly
- [ ] `README.md` and `docs/infra-target-architecture.html` updated in the same PR when they describe what changed
- [ ] Anything `../cvhome` (or another cvhome-saas repo) must change is named in the PR body under *Deviations*

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
  prod. Private subnets everywhere: one NAT gateway under prod, one NAT instance below it
  (`flavours.yaml` `network.egress`). Public task IPs were the cheap option until AWS began billing every
  public IPv4 by the hour; fifteen of them cost more than a t4g.nano and its one address.
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

---

<!-- Added by AWS Agent Toolkit setup (advanced AWS experience), 2026-08-28 -->

# AWS Guidance

- Prefer the AWS MCP Server for AWS interactions — it provides sandboxed
  execution, observability, and audit logging. If unavailable, use the
  AWS CLI directly.
- Before starting a task, check whether a relevant AWS skill is available.
  Load the skill with `retrieve_skill` and prefer its guidance over
  general knowledge.
- When uncertain about specific AWS details (API parameters, permissions,
  limits, error codes), verify against documentation rather than guessing.
  State uncertainty explicitly if you cannot confirm.
- When creating infrastructure, prefer infrastructure-as-code (AWS CDK or
  CloudFormation) over direct CLI commands.
- When working with infrastructure, follow AWS Well-Architected Framework
  principles.
- Do not use em dashes in AWS resource names or descriptions. Use
  hyphens instead.

## Secret Safety

- MUST load the `aws-secrets-manager` skill first for any secret,
  credential, API key, token, or password task. MUST NOT call
  `secretsmanager get-secret-value` or `batch-get-secret-value`, and MUST
  NOT hit the Secrets Manager Agent daemon directly. MUST use
  `{{resolve:secretsmanager:secret-id:SecretString:json-key}}` with
  `asm-exec` so the secret resolves at runtime without entering context.
