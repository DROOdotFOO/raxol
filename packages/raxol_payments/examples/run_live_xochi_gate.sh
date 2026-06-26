#!/usr/bin/env bash
# Run the live Xochi crosschain payment gate against the Xochi worker.
#
# The worker (api.xochi.fi) serves the /api/intent/* routes the raxol client
# calls, applies trust-tier fees, and calls the Riddler solver internally.
#
# Auth (XOCHI_LIVE_AUTH, default "mandate"):
#   mandate -- the agent-native path. The funded key signs an EIP-712 delegation
#     envelope and self-delegates, which Raxol.Payments.Req.Mandate presents as
#     X-Xochi-Delegation on quote/execute, inheriting the key's Member tier. The
#     worker scopes mandates to quote/execute only, so /status polling falls back
#     to the Member service token -- a mandate run needs BOTH the funded key and
#     the service token.
#   member -- drive the whole quote -> execute -> poll lifecycle off the Member
#     service token. One token covers everything, with no per-call x402 Guest
#     micropayment (each /status poll would otherwise pay). Required where x402 is
#     disabled and no mandate is provisioned.
#
# The Member service token is a long-lived credential in 1Password (never
# expires; rotate to revoke), per-env:
#   prod:    op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential (default)
#   staging: op://Employee/Xochi staging AGENT_SERVICE_TOKENS/credential
# Staging (api-stg.xochi.fi) has x402 disabled, so Member is the only auth path
# there; rehearse the dry-run on staging first.
#
# This MOVES REAL FUNDS. Default route is a $1.10 (1.10 USDC) Base -> Arbitrum
# transfer. The solver enforces a corridor minimum of strictly more than 1.00 USDC
# (exactly 1.00 quotes back can_solve=false with amount_below_minimum on both
# legs), so the default sits just above the floor with margin for pricing/slippage.
# The solver fills on the destination chain, and its USDC fill inventory currently
# lives on Arbitrum (verified on-chain), so Arbitrum is the corridor a real run can
# actually settle. The test file runs two cases, so a full run settles ~2.20 USDC
# total (the end-to-end transfer + the crash-resume transfer). A passing quote
# (can_solve) is a pricing check; only inventory on the destination guarantees a
# real fill. Settlement defaults to public.
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
# Overrides: XOCHI_LIVE_AUTH (mandate|member), XOCHI_LIVE_AGENT_WALLET,
# XOCHI_LIVE_URL, XOCHI_LIVE_TOKEN, XOCHI_LIVE_AMOUNT (human USDC, default 1.10;
# the solver floor is >1.00, so 1.00 or below aborts at preflight),
# XOCHI_LIVE_FROM_CHAIN / XOCHI_LIVE_TO_CHAIN, XOCHI_LIVE_FROM_TOKEN /
# XOCHI_LIVE_TO_TOKEN, plus XOCHI_LIVE_SETTLEMENT=stealth with
# XOCHI_LIVE_RECIPIENT_META for the private path.
#
# Matrix mode (XOCHI_LIVE_MATRIX=true): settle every corridor for each settlement
# type in one run, MOVING REAL FUNDS PER CELL. Bounded by:
#   XOCHI_LIVE_CORRIDORS    "from>to,from>to" chain ids (default 8453>42161,42161>8453)
#   XOCHI_LIVE_SETTLEMENTS  "public,stealth" (default public; stealth needs META)
#   XOCHI_LIVE_AMOUNT       per-cell amount
# USDC is resolved per chain for Base/Optimism/Arbitrum. Example:
#   XOCHI_LIVE_KEY=0x<funded> XOCHI_LIVE_MATRIX=true \
#   XOCHI_LIVE_SETTLEMENTS=public,stealth XOCHI_LIVE_RECIPIENT_META=st:eth:0x... \
#     ./examples/run_live_xochi_gate.sh
set -euo pipefail

XOCHI_LIVE_URL="${XOCHI_LIVE_URL:-https://api.xochi.fi}"
XOCHI_LIVE_AUTH="${XOCHI_LIVE_AUTH:-mandate}"
OP_TOKEN_REF="${OP_TOKEN_REF:-op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential}"
XOCHI_LIVE_AMOUNT="${XOCHI_LIVE_AMOUNT:-1.10}"
XOCHI_LIVE_FROM_CHAIN="${XOCHI_LIVE_FROM_CHAIN:-8453}"
XOCHI_LIVE_TO_CHAIN="${XOCHI_LIVE_TO_CHAIN:-42161}"
XOCHI_LIVE_FROM_TOKEN="${XOCHI_LIVE_FROM_TOKEN:-0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913}"
XOCHI_LIVE_TO_TOKEN="${XOCHI_LIVE_TO_TOKEN:-0xaf88d065e77c8cc2239327c5edb3a432268e5831}"

# Matrix mode (XOCHI_LIVE_MATRIX=true): settle every corridor x settlement type.
# Each cell moves real funds; bounded by the corridor/settlement lists below.
XOCHI_LIVE_MATRIX="${XOCHI_LIVE_MATRIX:-false}"
XOCHI_LIVE_CORRIDORS="${XOCHI_LIVE_CORRIDORS:-8453>42161,42161>8453}"
XOCHI_LIVE_SETTLEMENTS="${XOCHI_LIVE_SETTLEMENTS:-public}"

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

# The preflight quote uses the Member token to confirm connectivity + can_solve
# (and that the token polling will need is valid). In mandate mode the gate's own
# quote/execute then authenticate via the signed X-Xochi-Delegation envelope,
# which the Elixir test builds and exercises; signing EIP-712 in bash is not
# practical here.
printf 'preflight (auth=%s): quoting %s USDC %s -> %s (read-only, no funds move)...\n' \
  "$XOCHI_LIVE_AUTH" "$XOCHI_LIVE_AMOUNT" "$XOCHI_LIVE_FROM_CHAIN" "$XOCHI_LIVE_TO_CHAIN" >&2
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
  printf 'a 401/402 means the Member Bearer token was not accepted. Fix auth\n' >&2
  printf '(check OP_TOKEN_REF matches XOCHI_LIVE_URL env). Aborting; no funds moved.\n' >&2
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

export XOCHI_LIVE_URL XOCHI_LIVE_TOKEN XOCHI_LIVE_KEY XOCHI_LIVE_AMOUNT \
  XOCHI_LIVE_FROM_CHAIN XOCHI_LIVE_TO_CHAIN XOCHI_LIVE_FROM_TOKEN XOCHI_LIVE_TO_TOKEN \
  XOCHI_LIVE_AUTH

if [[ "$XOCHI_LIVE_MATRIX" == "true" ]]; then
  export XOCHI_LIVE_MATRIX XOCHI_LIVE_CORRIDORS XOCHI_LIVE_SETTLEMENTS
  if [[ -n "${XOCHI_LIVE_RECIPIENT_META:-}" ]]; then
    export XOCHI_LIVE_RECIPIENT_META
  fi
  printf 'matrix mode: settling [%s] x [%s] at %s USDC each (REAL funds)...\n' \
    "$XOCHI_LIVE_CORRIDORS" "$XOCHI_LIVE_SETTLEMENTS" "$XOCHI_LIVE_AMOUNT" >&2
  exec env MIX_ENV=test mix test --only live_xochi_matrix \
    test/raxol/payments/xochi/live_xochi_test.exs
fi

printf 'running the gate: this submits REAL mainnet intents and settles ~%s USDC per case...\n' \
  "$XOCHI_LIVE_AMOUNT" >&2
exec env MIX_ENV=test mix test --include live_xochi \
  test/raxol/payments/xochi/live_xochi_test.exs
