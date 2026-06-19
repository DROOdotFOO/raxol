#!/usr/bin/env bash
# Run the live Xochi crosschain stealth payment gate against the Riddler solver.
#
# Riddler serves the /xochi/* routes the raxol client calls. The bearer token is
# the staging-scoped Riddler token in 1Password. You supply a funded Base
# Sepolia private key (the intent moves real testnet USDC).
#
# Usage (from packages/raxol_payments/):
#   XOCHI_LIVE_KEY=0x<funded base-sepolia key> ./examples/run_live_xochi_gate.sh
#
# Override the endpoint or token source with XOCHI_LIVE_URL / XOCHI_LIVE_TOKEN.
set -euo pipefail

XOCHI_LIVE_URL="${XOCHI_LIVE_URL:-https://riddler.axol.io}"
OP_TOKEN_REF="${OP_TOKEN_REF:-op://Employee/Xochi staging RIDDLER_API_TOKEN/credential}"

if [[ -z "${XOCHI_LIVE_KEY:-}" ]]; then
  printf 'error: set XOCHI_LIVE_KEY to a funded Base Sepolia (84532) private key\n' >&2
  exit 1
fi

if [[ -z "${XOCHI_LIVE_TOKEN:-}" ]]; then
  if ! command -v op >/dev/null 2>&1; then
    printf 'error: op CLI not found; set XOCHI_LIVE_TOKEN directly\n' >&2
    exit 1
  fi
  printf 'reading Riddler token from 1Password (%s)...\n' "$OP_TOKEN_REF" >&2
  XOCHI_LIVE_TOKEN="$(op read "$OP_TOKEN_REF")"
fi

printf 'validating quote endpoint (read-only, no funds move)...\n' >&2
quote_body='{"wallet":"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045","from_chain_id":84532,"to_chain_id":421614,"from_token":"0x036CbD53842c5426634e7929541eC2318f3dCF7e","to_token":"0x036CbD53842c5426634e7929541eC2318f3dCF7e","from_amount":"100000","settlement_preference":"stealth","slippage_bps":50}'
code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
  -X POST "$XOCHI_LIVE_URL/xochi/quote" \
  -H "authorization: Bearer $XOCHI_LIVE_TOKEN" \
  -H 'content-type: application/json' \
  -d "$quote_body")"

if [[ "$code" == "422" ]]; then
  printf 'error: quote returned 422 -- Riddler at %s lacks the snake_case fix (need image >= 0ae99e7)\n' "$XOCHI_LIVE_URL" >&2
  exit 1
elif [[ "$code" != "200" ]]; then
  printf 'warning: quote probe returned http %s (continuing to the gate)\n' "$code" >&2
else
  printf 'quote ok (http 200). running the full gate (this submits a real testnet intent)...\n' >&2
fi

export XOCHI_LIVE_URL XOCHI_LIVE_TOKEN XOCHI_LIVE_KEY
exec env MIX_ENV=test mix test --include live_xochi \
  test/raxol/payments/xochi/live_xochi_test.exs
