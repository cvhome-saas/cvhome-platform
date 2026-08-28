env     = "prod"
flavour = "prod"
region  = "eu-central-1"

test_stores = false
az_count    = 3

# Example of the override mechanism: prod's shape, with a larger database, without
# forking the flavour. Merged one level deep over flavours.yaml.
# flavour_overrides = {
#   rds = {
#     instance_class = "db.t4g.medium"
#   }
# }
