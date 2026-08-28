#!/usr/bin/env bash
#
# Wake a hibernated environment: start the databases, wait for them, then rebuild
# compute.
#
# ORDER MATTERS, and it is the reverse of hibernate. The databases come up first and
# are waited for, because the ECS services Terraform is about to create will try to
# connect on their first health check. Starting an RDS instance takes minutes, and a
# service that starts against a database still booting fails its health check, gets
# killed by the circuit breaker, and rolls the deployment back.
#
#   Usage: wake.sh <env>

set -euo pipefail

ENV_NAME="${1:?usage: wake.sh <env>}"
PROJECT_ID="${PROJECT_ID:?PROJECT_ID must be set}"
AWS_REGION="${AWS_REGION:?AWS_REGION must be set}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:?TF_STATE_BUCKET must be set}"

VARFILE="envs/${ENV_NAME}.tfvars"
[ -f "$VARFILE" ] || VARFILE="envs/dev.tfvars"

log() { printf '\n=== %s\n' "$*"; }

db_instances() {
  aws rds describe-db-instances \
    --query "DBInstances[?TagList[?Key=='Project' && Value=='${PROJECT_ID}'] && TagList[?Key=='Environment' && Value=='${ENV_NAME}']].[DBInstanceIdentifier,DBInstanceStatus]" \
    --output text
}

# Clear the flag first: the keeper Lambda re-stops databases while this reads "true",
# and it would happily stop the instance we are in the middle of starting.
log "Clearing the hibernation flag"
aws ssm put-parameter \
  --name "/${PROJECT_ID}/${ENV_NAME}/hibernated" \
  --value "false" --type String --overwrite >/dev/null

log "Starting databases"
ids=()
while read -r id status; do
  [ -z "$id" ] && continue
  ids+=("$id")
  case "$status" in
    stopped)
      echo "  starting $id"
      aws rds start-db-instance --db-instance-identifier "$id" >/dev/null
      ;;
    available)
      echo "  $id already available"
      ;;
    *)
      echo "  $id is '$status' — waiting for it below"
      ;;
  esac
done <<< "$(db_instances)"

if [ ${#ids[@]} -eq 0 ]; then
  echo "  no databases found for ${PROJECT_ID}/${ENV_NAME}" >&2
  echo "  if this environment has never been applied, run the pipeline instead" >&2
  exit 1
fi

log "Waiting for databases to become available"
for id in "${ids[@]}"; do
  echo "  waiting on $id"
  # Roughly 40 minutes of headroom. A cold start of a stopped instance is usually
  # under ten, but a version upgrade applied at start time can take considerably longer.
  aws rds wait db-instance-available --db-instance-identifier "$id"
  echo "  $id available"
done

log "Recreating compute"
terraform init -input=false \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=env/${ENV_NAME}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}"

terraform apply -auto-approve -input=false \
  -var="project=${PROJECT_ID}" \
  -var="env=${ENV_NAME}" \
  -var="region=${AWS_REGION}" \
  -var="hibernated=false" \
  -var-file="$VARFILE"

log "Awake"
terraform output console_url
cat <<'SUMMARY'

  Terraform has finished, which is not the same as the environment being ready:
  it returns once ECS accepts the deployments, not once tasks pass health checks.
  Spring services take a minute or two beyond that.

  Watch: aws ecs describe-services --cluster <cluster> --services <service> \
           --query 'services[].deployments'
SUMMARY
