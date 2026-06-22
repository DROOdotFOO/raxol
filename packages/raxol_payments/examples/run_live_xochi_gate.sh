#!/usr/bin/env bash
# Run the live Xochi crosschain payment gate against the Xochi worker.
#
# The worker (api.xochi.fi) serves the /api/intent/* routes the raxol client
# calls, applies trust-tier fees, and calls the Riddler solver internally. Auth
# is a long-lived Member service token in 1Password (never expires; rotate to
# revoke): one token covers the whole quote -> execute -> poll lifecycle, which is
# why the gate uses Member rather than per-call x402 Guest micropayments (each
# /status poll would pay). The token is per-env:
#   prod:    op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential (default)
#   staging: op://Employee/Xochi staging AGENT_SERVICE_TOKENS/credential
# Staging (api-stg.xochi.fi) has x402 disabled, so Member is the only auth path
# there; rehearse the dry-run on staging first.
#
# This MOVES REAL FUNDS. Default route is a $1 (1 USDC) Base -> Optimism transfer,
# the corridor Xochi verified fills at $1 on prod. The test file runs two cases,
# so a full run settles ~2 USDC total (the end-to-end transfer + the crash-resume
# transfer). Settlement defaults to public.
#
# Rehearse on staging first (Member-only there; DRY_RUN needs no funds):
#   XOCHI_LIVE_URL=https://api-stg.xochi.fi \
#   OP_TOKEN_REF=op://Employee/Xochi staging AGENT_SERVICE_TOKENS/credential \
#     XOCHI_LIVE_KEY=0xdummy DRY_RUN=1 ./examples/run_live_xochi_gate.sh
#
# Then prod, safest first:
#   # 1. Dry run: quote-only, NO funds move. Confirms auth + the $1 fill.
#   XOCHI_LIVE_KEY=0xdummy DRY_RUN=1 ./examples/run_live_xochi_gate.sh
#
#   # 2. Real run: submits mainnet intents and settles (needs a funded key).
#   XOCHI_LIVE_KEY=0x<funded base key> ./examples/run_live_xochi_gate.sh
#
# Overrides: XOCHI_LIVE_URL, XOCHI_LIVE_TOKEN, XOCHI_LIVE_AMOUNT (human USDC,
# default 1.00), XOCHI_LIVE_FROM_CHAIN / XOCHI_LIVE_TO_CHAIN,
# XOCHI_LIVE_FROM_TOKEN / XOCHI_LIVE_TO_TOKEN, plus XOCHI_LIVE_SETTLEMENT=stealth
# with XOCHI_LIVE_RECIPIENT_META for the private path.
set -euo pipefail

XOCHI_LIVE_URL="${XOCHI_LIVE_URL:-https://api.xochi.fi}"
OP_TOKEN_REF="${OP_TOKEN_REF:-op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential}"
XOCHI_LIVE_AMOUNT="${XOCHI_LIVE_AMOUNT:-1.00}"
XOCHI_LIVE_FROM_CHAIN="${XOCHI_LIVE_FROM_CHAIN:-8453}"
XOCHI_LIVE_TO_CHAIN="${XOCHI_LIVE_TO_CHAIN:-10}"
XOCHI_LIVE_FROM_TOKEN="${XOCHI_LIVE_FROM_TOKEN:-0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913}"
XOCHI_LIVE_TO_TOKEN="${XOCHI_LIVE_TO_TOKEN:-0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85}"

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

# USDC has 6 decimals; convert the human amount to atomic units for the probe.
atomic="$(awk -v a="$XOCHI_LIVE_AMOUNT" 'BEGIN { printf "%d", a * 1000000 }')"

printf 'preflight: quoting %s USDC %s -> %s (read-only, no funds move)...\n' \
  "$XOCHI_LIVE_AMOUNT" "$XOCHI_LIVE_FROM_CHAIN" "$XOCHI_LIVE_TO_CHAIN" >&2
# Mirror the fields Raxol.Payments.Xochi.Schemas.QuoteRequest.to_json sends;
# `deadline` is required by the worker (a future unix ts, max 1h ahead).
deadline="$(( $(date +%s) + 300 ))"
quote_body="$(printf '{"wallet":"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045","from_chain_id":%s,"to_chain_id":%s,"from_token":"%s","to_token":"%s","from_amount":"%s","settlement_preference":"public","slippage_bps":50,"deadline":%s,"gasless":false}' \
  "$XOCHI_LIVE_FROM_CHAIN" "$XOCHI_LIVE_TO_CHAIN" "$XOCHI_LIVE_FROM_TOKEN" "$XOCHI_LIVE_TO_TOKEN" "$atomic" "$deadline")"
probe="$(curl -sS -m 20 -w '\n%{http_code}' \
  -X POST "$XOCHI_LIVE_URL/api/intent/quote" \
  -H "authorization: Bearer $XOCHI_LIVE_TOKEN" \
  -H 'content-type: application/json' \
  -d "$quote_body")"
code="${probe##*$'\n'}"
body="${probe%$'\n'*}"

if [[ "$code" != "200" ]]; then
  printf 'preflight FAILED: quote returned http %s: %s\n' "$code" "$body" >&2
  printf 'a 401/402 means the Member Bearer token was not accepted. Fix auth before\n' >&2
  printf 'the real run (or wait on Xochi mandate verification). Aborting; no funds moved.\n' >&2
  exit 1
fi

if ! grep -qE '"can_solve"[[:space:]]*:[[:space:]]*true' <<<"$body"; then
  printf 'preflight FAILED: quote ok (http 200) but can_solve != true:\n%s\n' "$body" >&2
  printf 'the solver will not fill this corridor/amount. Aborting; no funds moved.\n' >&2
  exit 1
fi

printf 'preflight ok: can_solve=true at %s USDC.\n' "$XOCHI_LIVE_AMOUNT" >&2

if [[ -n "${DRY_RUN:-}" ]]; then
  printf 'DRY_RUN set: auth + fill confirmed, NO funds moved.\n' >&2
  printf 're-run without DRY_RUN to submit the real mainnet intents.\n' >&2
  exit 0
fi

printf 'running the gate: this submits REAL mainnet intents and settles ~%s USDC per case...\n' \
  "$XOCHI_LIVE_AMOUNT" >&2

export XOCHI_LIVE_URL XOCHI_LIVE_TOKEN XOCHI_LIVE_KEY XOCHI_LIVE_AMOUNT \
  XOCHI_LIVE_FROM_CHAIN XOCHI_LIVE_TO_CHAIN XOCHI_LIVE_FROM_TOKEN XOCHI_LIVE_TO_TOKEN
exec env MIX_ENV=test mix test --include live_xochi \
  test/raxol/payments/xochi/live_xochi_test.exs
