# Human choices for dev. Everything not set here comes from the flavour, and everything
# the bootstrap generated (zone, pod ids, image tag) comes from SSM. This file wins.

# Region is deliberately not set here. It comes from the CodeBuild environment via
# -var="region=$AWS_REGION", which is the region the bootstrap stack was deployed to.
# Pinning it in this file lets the two disagree silently: the deploy role guards the
# Infrastructure grant with aws:RequestedRegion = the stack region, so a tfvars region
# that differs makes every call fail as "no identity-based policy allows" even for
# actions that are granted.

env     = "dev"
flavour = "dev"

# Cheapest thing that runs the whole product.
test_stores = true
az_count    = 2
