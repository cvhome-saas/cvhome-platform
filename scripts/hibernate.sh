#!/usr/bin/env bash
#
# Hibernate an environment: destroy everything billed by the hour, keep everything
# holding state, then stop the databases.
#
#   destroyed   ECS services and tasks, ALB, per-pod NLBs, NAT gateway, and the
#               Route53 records that alias them
#   kept        RDS instances (stopped), S3 buckets, CloudFront distributions,
#               Secrets Manager, ECR images, the VPC, Cloud Map namespaces and the
#               ECS clusters — all either free or holding state
#
# Nothing an application can observe changes across a hibernate/wake cycle. The RDS
# endpoint survives because the instance is stopped rather than deleted; the CloudFront
# domain survives, so media URLs already stored in the database still resolve; and
# every hostname survives because the DNS records are aliases pointing at whatever
# load balancer exists at the time.
#
# ORDER MATTERS. Compute is destroyed first, so nothing is holding a database
# connection when the stop is requested. A stop with active connections is rejected.
#
#   Usage: hibernate.sh <env>
#
# THE SEVEN DAY LIMIT
#   RDS will not stay stopped indefinitely: AWS starts a stopped instance again after
#   seven days. The keeper Lambda the bootstrap stack creates re-stops it each day
#   while /{project}/{env}/hibernated reads "true", so hibernation survives past a
#   week. If that Lambda is removed, an environment silently starts billing for
#   database compute again on day eight.

set -euo pipefail

ENV_NAME="${1:?usage: hibernate.sh <env>}"
PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
AWS_REGION="${AWS_REGION:?AWS_REGION must be set}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:?TF_STATE_BUCKET must be set}"

VARFILE="envs/${ENV_NAME}.tfvars"
[ -f "$VARFILE" ] || VARFILE="envs/dev.tfvars"

log() { printf '\n=== %s\n' "$*"; }

# Instances are found by tag rather than by name, so this keeps working when the
# naming scheme changes and covers every pod without being told how many there are.
db_instances() {
  aws rds describe-db-instances \
    --query "DBInstances[?TagList[?Key=='Project' && Value=='${PROJECT_ID}'] && TagList[?Key=='Environment' && Value=='${ENV_NAME}']].[DBInstanceIdentifier,DBInstanceStatus]" \
    --output text
}

log "Marking ${PROJECT_ID}/${ENV_NAME} as hibernated"
# Written before anything is destroyed. If the run dies halfway, the keeper still
# knows this environment is meant to be asleep.
aws ssm put-parameter \
  --name "/${PROJECT_ID}/${ENV_NAME}/hibernated" \
  --value "true" --type String --overwrite >/dev/null

log "Destroying compute"
terraform init -input=false \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=env/${ENV_NAME}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}"

terraform apply -auto-approve -input=false \
  -var="project=${PROJECT_ID}" \
  -var="env=${ENV_NAME}" \
  -var="region=${AWS_REGION}" \
  -var="hibernated=true" \
  -var-file="$VARFILE"

log "Stopping databases"
# Terraform cannot express this: aws_db_instance has no attribute for run state, only
# a read-only status. So the stop is an API call, and Terraform is never told.
stopped=0
while read -r id status; do
  [ -z "$id" ] && continue
  case "$status" in
    available)
      echo "  stopping $id"
      aws rds stop-db-instance --db-instance-identifier "$id" >/dev/null
      stopped=$((stopped + 1))
      ;;
    stopped|stopping)
      echo "  $id already $status"
      ;;
    *)
      echo "  $id is '$status' — not stoppable right now; the keeper will retry" >&2
      ;;
  esac
done <<< "$(db_instances)"

log "Hibernated"
cat <<SUMMARY
  ${PROJECT_ID}/${ENV_NAME} is asleep.
  Databases stopped this run: ${stopped}

  Still billing: RDS storage and backups, S3 storage, ECR storage, Secrets Manager,
  the hosted zone, and one Route53 private hosted zone per Cloud Map namespace.
  No longer billing: Fargate tasks, load balancer hours, NAT hours.

  Wake it with: scripts/wake.sh ${ENV_NAME}
SUMMARY
