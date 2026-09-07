# Region is deliberately not set here. It comes from the CodeBuild environment via
# -var="region=$AWS_REGION", which is the region the bootstrap stack was deployed to.
# Pinning it in this file lets the two disagree silently: the deploy role guards the
# Infrastructure grant with aws:RequestedRegion = the stack region, so a tfvars region
# that differs makes every call fail as "no identity-based policy allows" even for
# actions that are granted.

env     = "prod"
flavour = "prod"

# Product version this environment runs; changed by the orchestrator's promotion PR
# (cvhome-saas/orchestrator docs/release-plan.md). `latest` only until the first
# tagged release (2.0.0).
image_tag = "latest"

test_stores = false
az_count    = 3

# Example of the override mechanism: prod's shape, with a larger database, without
# forking the flavour. Merged one level deep over flavours.yaml.
# flavour_overrides = {
#   rds = {
#     instance_class = "db.t4g.medium"
#   }
# }
