#!/usr/bin/env bash
# Run the live Tron Relay quote gate against the Riddler solver (read-only).
#
# Riddler serves the /relay/* routes the raxol Relay client calls. A quote moves
# no funds, so this needs no private key -- just the endpoint, the staging bearer
# token, and the EVM source address the quote is priced for.
#
# The full EVM->Tron settlement (which broadcasts an on-chain deposit) is a
# separate raxol_acp :live_relay test, since broadcasting needs the EVM tx stack.
#
# Usage (from packages/raxol_payments/):
#   RELAY_LIVE_FROM_ADDRESS=0x<base address> ./examples/run_live_relay_gate.sh
#
# Override the endpoint or token source with RELAY_LIVE_URL / RELAY_LIVE_TOKEN.
set -euo pipefail

RELAY_LIVE_URL="${RELAY_LIVE_URL:-https://riddler.axol.io}"
OP_TOKEN_REF="${OP_TOKEN_REF:-op://Employee/Xochi staging RIDDLER_API_TOKEN/credential}"
RELAY_LIVE_FROM_TOKEN="${RELAY_LIVE_FROM_TOKEN:-0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913}"
RELAY_LIVE_TO_TOKEN="${RELAY_LIVE_TO_TOKEN:-TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t}"
RELAY_LIVE_TO_ADDRESS="${RELAY_LIVE_TO_ADDRESS:-TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t}"
RELAY_LIVE_AMOUNT="${RELAY_LIVE_AMOUNT:-100000}"

if [[ -z "${RELAY_LIVE_FROM_ADDRESS:-}" ]]; then
  printf 'error: set RELAY_LIVE_FROM_ADDRESS to the EVM source (Base) address\n' >&2
  exit 1
fi

if [[ -z "${RELAY_LIVE_TOKEN:-}" ]]; then
  if ! command -v op >/dev/null 2>&1; then
    printf 'error: op CLI not found; set RELAY_LIVE_TOKEN directly\n' >&2
    exit 1
  fi
  printf 'reading Riddler token from 1Password (%s)...\n' "$OP_TOKEN_REF" >&2
  RELAY_LIVE_TOKEN="$(op read "$OP_TOKEN_REF")"
fi

printf 'validating relay quote endpoint (read-only, no funds move)...\n' >&2
quote_body="$(printf '{"transfer_id":"probe","from_chain_id":8453,"to_chain_id":728126428,"from_token":"%s","to_token":"%s","from_amount":"%s","from_address":"%s","to_address":"%s","slippage_bps":50}' \
  "$RELAY_LIVE_FROM_TOKEN" "$RELAY_LIVE_TO_TOKEN" "$RELAY_LIVE_AMOUNT" "$RELAY_LIVE_FROM_ADDRESS" "$RELAY_LIVE_TO_ADDRESS")"

code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
  -X POST "$RELAY_LIVE_URL/relay/quote" \
  -H "authorization: Bearer $RELAY_LIVE_TOKEN" \
  -H 'content-type: application/json' \
  -d "$quote_body")"

if [[ "$code" != "200" ]]; then
  printf 'warning: relay quote probe returned http %s (continuing to the gate)\n' "$code" >&2
else
  printf 'relay quote ok (http 200). running the gate...\n' >&2
fi

export RELAY_LIVE_URL RELAY_LIVE_TOKEN RELAY_LIVE_FROM_ADDRESS
export RELAY_LIVE_FROM_TOKEN RELAY_LIVE_TO_TOKEN RELAY_LIVE_TO_ADDRESS RELAY_LIVE_AMOUNT
exec env MIX_ENV=test mix test --include live_relay \
  test/raxol/payments/relay/live_relay_test.exs
