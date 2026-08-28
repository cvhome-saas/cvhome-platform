#!/usr/bin/env bash
#
# Register (or update) the Stripe webhook endpoint for this environment, and store the
# resulting signing secret where the billing service reads it.
#
# Run after the environment applies, not at bootstrap time: the endpoint URL contains
# the domain, and the domain does not exist until the load balancer does.
#
# The path matters. The legacy bootstrap registered
#   /subscription/api/v1/stripe-webhook/public/events
# which did not survive the tenancy/billing split. StripeWebhookApi is
# @RequestMapping("/api/v1/stripe-webhook") inside billing, and the gateway routes
# /billing/** to lb://billing — so the real path is
#   /billing/api/v1/stripe-webhook/public/events
#
# Usage: register-stripe-webhook.sh <endpoint-url>

set -euo pipefail

ENDPOINT="${1:?usage: register-stripe-webhook.sh <endpoint-url>}"
SECRET_NAME="${STRIPE_SECRET:?STRIPE_SECRET must name the Secrets Manager secret}"

EVENTS=(
  checkout.session.completed
  customer.subscription.created
  customer.subscription.updated
  customer.subscription.deleted
  invoice.paid
  invoice.payment_failed
)

payload="$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text)"
api_key="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("STRIPE_KEY",""))')"

if [ -z "$api_key" ]; then
  echo "No Stripe key configured — skipping webhook registration." >&2
  exit 0
fi

echo "Registering Stripe webhook -> $ENDPOINT"

args=(--silent --show-error --fail-with-body -u "${api_key}:" -d "url=${ENDPOINT}")
for e in "${EVENTS[@]}"; do args+=(-d "enabled_events[]=${e}"); done

# Reuse the existing endpoint for this URL rather than accumulating duplicates on
# every apply.
existing="$(curl --silent --fail -u "${api_key}:" \
  "https://api.stripe.com/v1/webhook_endpoints?limit=100" \
  | python3 -c "
import json,sys
url=sys.argv[1]
data=json.load(sys.stdin).get('data',[])
print(next((w['id'] for w in data if w.get('url')==url), ''))
" "$ENDPOINT")"

if [ -n "$existing" ]; then
  echo "Endpoint already registered ($existing) — updating events."
  curl "${args[@]}" -X POST "https://api.stripe.com/v1/webhook_endpoints/${existing}" > /dev/null
  echo "Signing secret unchanged; leaving the stored value alone."
  exit 0
fi

# The signing secret is returned only on creation, so it must be captured now.
signing_secret="$(curl "${args[@]}" -X POST "https://api.stripe.com/v1/webhook_endpoints" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("secret",""))')"

if [ -z "$signing_secret" ]; then
  echo "Stripe did not return a signing secret." >&2
  exit 1
fi

updated="$(printf '%s' "$payload" | python3 -c '
import json,sys
doc = json.load(sys.stdin)
doc["STRIPE_WEBHOOK-SIGNING-KEY"] = sys.argv[1]
print(json.dumps(doc))
' "$signing_secret")"

aws secretsmanager put-secret-value \
  --secret-id "$SECRET_NAME" \
  --secret-string "$updated" > /dev/null

echo "Webhook registered and signing secret stored."
echo "Note: billing tasks pick it up on their next deployment."
