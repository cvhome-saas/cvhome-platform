# Human choices for dev. Everything not set here comes from the flavour, and everything
# the bootstrap generated (zone, pod ids) comes from SSM. This file wins.

# Region is deliberately not set here. It comes from the CodeBuild environment via
# -var="region=$AWS_REGION", which is the region the bootstrap stack was deployed to.
# Pinning it in this file lets the two disagree silently: the deploy role guards the
# Infrastructure grant with aws:RequestedRegion = the stack region, so a tfvars region
# that differs makes every call fail as "no identity-based policy allows" even for
# actions that are granted.

env     = "dev"
flavour = "dev"

# Product version this environment runs; changed by the orchestrator's promotion PR
# (cvhome-saas/orchestrator docs/release-plan.md). `latest` only until the first
# tagged release (2.0.0).
image_tag = "2.0.0"

# Cheapest thing that runs the whole product.
test_stores = true
az_count    = 2
