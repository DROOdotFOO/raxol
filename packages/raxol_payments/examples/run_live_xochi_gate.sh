#!/usr/bin/env bash
# Run the live Xochi crosschain payment gate against the Xochi worker.
#
# The worker (api.xochi.fi, or api-stg.xochi.fi for staging) serves the
# /api/intent/* routes the raxol client calls, applies trust-tier fees, and
# calls the Riddler solver internally. The bearer token is the Xochi worker
# token in 1Password. This MOVES REAL FUNDS: you supply a funded Base mainnet
# private key, and the default route is Base -> Arbitrum USDC at 10 USDC.
#
# Settlement defaults to public. For the private path, set
# XOCHI_LIVE_SETTLEMENT=stealth and XOCHI_LIVE_RECIPIENT_META=st:eth:0x...
#
# Usage (from packages/raxol_payments/):
#   XOCHI_LIVE_KEY=0x<funded base mainnet key> ./examples/run_live_xochi_gate.sh
#
# Override the endpoint or token source with XOCHI_LIVE_URL / XOCHI_LIVE_TOKEN.
set -euo pipefail

XOCHI_LIVE_URL="${XOCHI_LIVE_URL:-https://api.xochi.fi}"
OP_TOKEN_REF="${OP_TOKEN_REF:-op://Employee/Xochi worker token/credential}"

if [[ -z "${XOCHI_LIVE_KEY:-}" ]]; then
  printf 'error: set XOCHI_LIVE_KEY to a funded Base mainnet (8453) private key\n' >&2
  exit 1
fi

if [[ -z "${XOCHI_LIVE_TOKEN:-}" ]]; then
  if ! command -v op >/dev/null 2>&1; then
    printf 'error: op CLI not found; set XOCHI_LIVE_TOKEN directly\n' >&2
    exit 1
  fi
  printf 'reading Xochi worker token from 1Password (%s)...\n' "$OP_TOKEN_REF" >&2
  XOCHI_LIVE_TOKEN="$(op read "$OP_TOKEN_REF")"
fi

printf 'validating quote endpoint (read-only, no funds move)...\n' >&2
quote_body='{"wallet":"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045","from_chain_id":8453,"to_chain_id":42161,"from_token":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","to_token":"0xaf88d065e77c8cc2239327c5edb3a432268e5831","from_amount":"10000000","settlement_preference":"public","slippage_bps":50}'
probe="$(curl -sS -m 20 -w '\n%{http_code}' \
  -X POST "$XOCHI_LIVE_URL/api/intent/quote" \
  -H "authorization: Bearer $XOCHI_LIVE_TOKEN" \
  -H 'content-type: application/json' \
  -d "$quote_body")"
code="${probe##*$'\n'}"
body="${probe%$'\n'*}"

if [[ "$code" != "200" ]]; then
  printf 'warning: quote probe returned http %s: %s (continuing to the gate)\n' "$code" "$body" >&2
else
  printf 'quote ok (http 200). running the gate (this submits a REAL mainnet intent)...\n' >&2
fi

export XOCHI_LIVE_URL XOCHI_LIVE_TOKEN XOCHI_LIVE_KEY
exec env MIX_ENV=test mix test --include live_xochi \
  test/raxol/payments/xochi/live_xochi_test.exs
