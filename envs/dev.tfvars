# Human choices for dev. Everything not set here comes from the flavour, and everything
# the bootstrap generated (zone, pod ids, image tag) comes from SSM. This file wins.

env     = "dev"
flavour = "dev"
region  = "eu-central-1"

# Cheapest thing that runs the whole product.
test_stores = true
az_count    = 2
