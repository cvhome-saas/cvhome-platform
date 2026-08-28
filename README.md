# cvhome-platform

Infrastructure for CVHome. One repository, replacing `cvhome-bootstrap`, `cvhome-infra`,
`cvhome-store-pod` and `cvhome-common-ecs-service`.

The architecture proposal this implements is in
[`docs/infra-target-architecture.html`](docs/infra-target-architecture.html) (and as
markdown in the application repo at `.agents/plans/infra-target-architecture.md`).

## Deploy

[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home#/stacks/create/review?stackName=cvhome-platform&templateURL=https://cvhome-saas.s3.eu-central-1.amazonaws.com/platform/bootstrap.yaml)

Launches in whichever region your console is currently in.

The button points at the template in S3, not at this repository: the CloudFormation
console's `templateURL` only accepts an S3 URL. `.github/workflows/publish-bootstrap.yml`
uploads `bootstrap/bootstrap.yaml` there on every push to `main`, and refuses to publish
a template that does not pass `cfn-lint`.

One click, then wait.

1. The stack asks for a project id, an environment name, a flavour, a hosted zone, a
   pod count and a Stripe key.
2. It writes the environment's config to SSM, creates the state bucket, a scoped deploy
   role and three CodeBuild projects — then **starts the pipeline**.
3. The pipeline runs itself:

   ```
   1-prereq   ECR repositories + ACM certificate, from services.yaml
   2-images   ./gradlew bootBuildImage --publishImage   (15 images)
   3-apply    terraform apply                            (everything else)
   ```

   Each stage starts the next only on success, so a failure stops the line instead of
   racing ahead to an apply that cannot work.

4. `terraform output console_url` tells you where to sign in.

To tear it down, run the `-destroy` CodeBuild project.

## Hibernating an environment

A dev environment that nobody is using still bills for Fargate tasks, load balancer
hours and a database. Hibernating destroys everything charged by the hour and keeps
everything holding state.

```bash
scripts/hibernate.sh dev     # or run the <project>-dev-hibernate CodeBuild project
scripts/wake.sh dev          # or <project>-dev-wake
```

| Destroyed | Kept |
|---|---|
| ECS services and tasks | RDS instances — **stopped**, not deleted |
| ALB, per-pod NLBs, target groups | S3 buckets: media, Caddy certificates, logs |
| NAT gateway | CloudFront distributions |
| Route53 records aliasing them | Secrets Manager, ECR images |
| | VPC, subnets, Cloud Map namespaces, ECS clusters |

Nothing the application can observe changes across the cycle. The RDS endpoint survives
because the instance is stopped rather than replaced; the CloudFront domain survives, so
media URLs already stored in the database still resolve; and hostnames survive because
the DNS records are aliases. While asleep the hostnames do not resolve at all — the
records point at load balancers that no longer exist, so they are removed with them.

**Order matters, and the two directions are not symmetric.** Hibernate destroys compute
*first*, then stops the databases, because a stop is rejected while connections are
open. Wake starts the databases and *waits* for them before creating services, because a
service that starts against a database still booting fails its health check and gets
rolled back by the circuit breaker.

**The seven-day limit.** AWS restarts a stopped RDS instance after seven days — there is
no way to opt out. The bootstrap stack creates a keeper Lambda that runs daily, reads
`/{project}/{env}/hibernated`, and re-stops anything AWS has woken. Without it a
hibernated environment quietly starts paying for database compute again on day eight.

Protected flavours refuse to hibernate. Load balancers under `prod` have deletion
protection on, which Terraform cannot disable and delete in one apply — and an
environment worth protecting is not one to put to sleep. The plan fails with that
explanation rather than part-way through the apply.

Hibernation does **not** stop storage costs: RDS storage and backups, S3, ECR and
Secrets Manager all continue, as does one Route53 private hosted zone per Cloud Map
namespace. It removes the compute and load balancer hours, which is the bulk of an idle
environment's bill.

## The two files that matter

### `services.yaml` — the service catalog

The single source of truth for all 15 services. Terraform `for_each`es it into ECR
repositories, ECS services, task definitions, environment variables, security-group
rules, load balancer target groups and DNS records.

**Adding a service is one entry.** Nothing else changes.

`scripts/check-catalog-drift.py` fails CI when this file disagrees with the application
repo, comparing against `common-config.yml`, `fargate-config.yml` and every
`build.gradle`. Run it any time:

```bash
python3 scripts/check-catalog-drift.py --app-repo ../cvhome
```

This is the check that would have caught the four services (`billing`, `pod-registry`,
`content`, `inventory`) the previous infrastructure never knew about, and the two it
knew under stale names.

### `flavours.yaml` — environment shapes

`dev`, `staging`, `prod`, `ephemeral`. One name fixes task sizing, desired counts,
Spot-versus-on-demand policy, RDS class and backups, log retention, monitoring and
networking. Override any key per environment in `envs/<env>.tfvars`:

```hcl
flavour = "prod"

flavour_overrides = {
  rds = { instance_class = "db.t4g.medium" }   # prod's shape, bigger database
}
```

Overrides merge one level deep into `rds`, `capacity` and `sizes`, so changing one field
does not mean restating the block.

## Layout

```
bootstrap/bootstrap.yaml   step 1 — the only CloudFormation left
services.yaml              the catalog
flavours.yaml              environment shapes
prereq/                    ECR + ACM. Applied before the image build.
modules/ecs-service/       one ECS service: task def, SG, Cloud Map, IAM, autoscaling
modules/network/           VPC, subnets, NAT (prod only)
modules/store-core/        cluster, ALB, RDS, the 6 core services
modules/store-pod/         per pod: cluster, NLB, RDS, CDN, the 9 pod services
envs/*.tfvars              human choices per environment
scripts/                   catalog drift check, Stripe webhook registration
main.tf …                  the environment root
```

Two Terraform states per environment, because of a hard ordering constraint — ECR does
not create repositories on push, and the ALB cannot reference an unissued certificate:

```
prereq/<env>/terraform.tfstate
env/<env>/terraform.tfstate
```

Both use S3 native locking (`use_lockfile`, Terraform ≥ 1.10). No DynamoDB table.

## Working on it

```bash
terraform fmt -recursive
terraform init -backend=false && terraform validate     # each root and module
python3 scripts/check-catalog-drift.py
cfn-lint bootstrap/bootstrap.yaml
```

CI runs all of these on every push and pull request
(`.github/workflows/terraform-validate.yml`). The first five jobs need no AWS
credentials, so they run on forks; only the plan job assumes a role, via OIDC.

**Applies never happen from GitHub Actions.** They happen in CodeBuild. The previous
setup applied from both, with two different project ids, against two different state
keys.

## Hostnames and environments

Below prod, every hostname sits under an environment label, so several environments can
share one hosted zone:

```
prod       gateway.com          console-ui.gateway.com          spg-<pod>.gateway.com
staging    staging.gateway.com  console-ui.staging.gateway.com  spg-<pod>.staging.gateway.com
dev        dev.gateway.com      console-ui.dev.gateway.com      spg-<pod>.dev.gateway.com
```

The prereq state mints a certificate for `<env-domain>` and `*.<env-domain>`, and the
environment root asserts the two agree before it applies. Override the label with
`dns_prefix` in both roots, or not at all.

Without this, every environment claimed the same records — apex, `www`, `uaa`,
`console-ui` and each pod — and the last apply won.

## Configuration precedence

```
flavours.yaml  <  SSM (/{project}/{env}/config)  <  envs/<env>.tfvars
```

SSM holds what the bootstrap generated — hosted zone, pod ids, image tag. `tfvars` holds
what a human chose, and wins. Someone who never touches git still gets a working
environment; a team that does gets reviewable diffs.

## Conventions

- Resources are named `${project}-${env}-*`. `project` is stable and settable, never
  random.
- Every declared variable is used. There is a check for this in the review checklist,
  because the previous code threaded four dead knobs through three module levels.
- Module sources are local paths. Nothing is pinned to a moving branch.
