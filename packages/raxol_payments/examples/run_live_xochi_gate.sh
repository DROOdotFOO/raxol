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
# Solver pin: the gate enforces the origin-pull solver pin by default -- the pull
# recipient (ERC-3009 `to` / Permit2 `spender`) must equal the canonical Riddler
# solver 0x97D447561fDe10E959E782a29411D8F89586d80b, so a forged or MITM'd quote
# that retargets the pull aborts before signing. Override the pinned address with
# XOCHI_LIVE_SOLVER (a solver rotation is an env change); set
# XOCHI_LIVE_SOLVER_PIN=false to disable the pin while debugging.
#
# Overrides: XOCHI_LIVE_AUTH (mandate|member), XOCHI_LIVE_AGENT_WALLET,
# XOCHI_LIVE_URL, XOCHI_LIVE_TOKEN, XOCHI_LIVE_AMOUNT (human USDC, default 1.10;
# the solver floor is >1.00, so 1.00 or below aborts at preflight),
# XOCHI_LIVE_FROM_CHAIN / XOCHI_LIVE_TO_CHAIN, XOCHI_LIVE_FROM_TOKEN /
# XOCHI_LIVE_TO_TOKEN, XOCHI_LIVE_SOLVER / XOCHI_LIVE_SOLVER_PIN for the solver
# pin, plus XOCHI_LIVE_SETTLEMENT=stealth with XOCHI_LIVE_RECIPIENT_META for the
# private path.
#
# Matrix mode (XOCHI_LIVE_MATRIX=true): validate every corridor x token x settlement
# type in one run. A read-only per-cell preflight runs first (quote every cell,
# assert can_solve, the served pull method per token, and the pinned solver); it
# aborts before any funds move if a cell fails, and is all that runs under DRY_RUN.
# The funded run then settles only the FILLABLE SUBSET: it re-quotes each cell and
# skips (logs) any the solver cannot fill right now. Bounded by:
#   XOCHI_LIVE_CORRIDORS         "from>to,from>to" chain ids, OR "mesh" for all 20
#                                ordered pairs of the 5 EVM chains (default 8453>42161,42161>8453)
#   XOCHI_LIVE_TOKENS            "USDC,USDT,WETH" (default USDC,USDT,WETH)
#   XOCHI_LIVE_SETTLEMENTS       "public,stealth" (default public; stealth needs META)
#   XOCHI_LIVE_AMOUNT            per-cell stablecoin amount (default 1.10)
#   XOCHI_LIVE_WETH_AMOUNT       per-cell WETH amount (default 0.001; 18-decimal token)
#   XOCHI_LIVE_ALLOW_ETH_ORIGIN  set true to settle Ethereum-origin cells (default: quote-only)
#   XOCHI_LIVE_SETTLE_PERMIT2    set true to settle USDT/WETH cells in the funded run
# Tokens resolve per chain via Raxol.Payments.Assets across the five EVM chains
# (1, 10, 137, 8453, 42161). USDC pulls via ERC-3009 and settles here directly.
# USDT/WETH pull via Permit2, which needs a standing on-chain Permit2 allowance this
# gate does not broadcast, so USDT/WETH funded cells are skipped by default: order
# them through raxol_acp (examples/run_live_acp_order_gate.sh, which sets the
# allowance and settles for real), or set XOCHI_LIVE_SETTLE_PERMIT2=true once the
# allowance is in place. Example (full 5x3 preflight + fillable USDC settlement):
#   XOCHI_LIVE_KEY=0x<funded> XOCHI_LIVE_MATRIX=true XOCHI_LIVE_CORRIDORS=mesh \
#   XOCHI_LIVE_TOKENS=USDC,USDT,WETH \
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
XOCHI_LIVE_TOKENS="${XOCHI_LIVE_TOKENS:-USDC,USDT,WETH}"
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
# The gas/price oracle occasionally returns a transient "temporarily unavailable"
# for a corridor that is otherwise fillable, and the worker can 5xx/429 under load.
# Quoting is read-only (no funds move), so retry the smoke-test probe a few times
# before aborting. A structural can_solve=false (e.g. amount_below_minimum) or an
# auth error (401/402) still aborts at once. Tunable via
# XOCHI_LIVE_PREFLIGHT_ATTEMPTS / XOCHI_LIVE_PREFLIGHT_BACKOFF.
preflight_attempts="${XOCHI_LIVE_PREFLIGHT_ATTEMPTS:-5}"
preflight_backoff="${XOCHI_LIVE_PREFLIGHT_BACKOFF:-3}"
transient_markers='gas_price_unavailable|temporarily|unavailable|oracle|timeout'

attempt=1
while true; do
  probe="$(curl -sS -m 20 -w '\n%{http_code}' \
    -X POST "$XOCHI_LIVE_URL/api/intent/quote" \
    -H "authorization: Bearer $XOCHI_LIVE_TOKEN" \
    -H 'content-type: application/json' \
    -d "$quote_body" || true)"
  code="${probe##*$'\n'}"
  body="${probe%$'\n'*}"

  if [[ "$code" == "200" ]] && grep -qE '"can_solve"[[:space:]]*:[[:space:]]*true' <<<"$body"; then
    printf 'preflight ok: can_solve=true at %s USDC.\n' "$XOCHI_LIVE_AMOUNT" >&2
    break
  fi

  # A 5xx/429/connection error, or a can_solve=false carrying an oracle marker, is
  # transient (retry). Everything else is structural (abort).
  transient=false
  if [[ -z "$code" || "$code" == "000" || "$code" == "429" || "$code" == 5* ]]; then
    transient=true
  elif [[ "$code" == "200" ]] && grep -qiE "$transient_markers" <<<"$body"; then
    transient=true
  fi

  if [[ "$transient" == "true" && "$attempt" -lt "$preflight_attempts" ]]; then
    printf 'preflight: transient quote (attempt %s/%s, http %s); retry in %ss...\n' \
      "$attempt" "$preflight_attempts" "${code:-none}" "$preflight_backoff" >&2
    attempt=$((attempt + 1))
    sleep "$preflight_backoff"
    continue
  fi

  if [[ "$code" != "200" ]]; then
    printf 'preflight FAILED: quote returned http %s: %s\n' "${code:-none}" "$body" >&2
    printf 'a 401/402 means the Member Bearer token was not accepted. Fix auth\n' >&2
    printf '(check OP_TOKEN_REF matches XOCHI_LIVE_URL env). Aborting; no funds moved.\n' >&2
  elif [[ "$transient" == "true" ]]; then
    printf 'preflight FAILED: oracle stayed unavailable across %s attempts (transient):\n%s\n' \
      "$preflight_attempts" "$body" >&2
    printf 'a temporary worker/oracle condition, not a bad corridor -- re-run shortly.\n' >&2
  else
    printf 'preflight FAILED: quote ok (http 200) but can_solve != true:\n%s\n' "$body" >&2
    printf 'the solver will not fill this corridor/amount. Aborting; no funds moved.\n' >&2
  fi
  exit 1
done

export XOCHI_LIVE_URL XOCHI_LIVE_TOKEN XOCHI_LIVE_KEY XOCHI_LIVE_AMOUNT \
  XOCHI_LIVE_FROM_CHAIN XOCHI_LIVE_TO_CHAIN XOCHI_LIVE_FROM_TOKEN XOCHI_LIVE_TO_TOKEN \
  XOCHI_LIVE_AUTH

# Matrix mode runs its own per-cell preflight + DRY_RUN, so branch before the
# single-corridor DRY_RUN exit below.
if [[ "$XOCHI_LIVE_MATRIX" == "true" ]]; then
  export XOCHI_LIVE_MATRIX XOCHI_LIVE_CORRIDORS XOCHI_LIVE_TOKENS XOCHI_LIVE_SETTLEMENTS
  if [[ -n "${XOCHI_LIVE_RECIPIENT_META:-}" ]]; then
    export XOCHI_LIVE_RECIPIENT_META
  fi
  if [[ -n "${XOCHI_LIVE_WETH_AMOUNT:-}" ]]; then
    export XOCHI_LIVE_WETH_AMOUNT
  fi
  if [[ -n "${XOCHI_LIVE_ALLOW_ETH_ORIGIN:-}" ]]; then
    export XOCHI_LIVE_ALLOW_ETH_ORIGIN
  fi
  if [[ -n "${XOCHI_LIVE_SETTLE_PERMIT2:-}" ]]; then
    export XOCHI_LIVE_SETTLE_PERMIT2
  fi

  # Per-cell preflight: quote every corridor x token read-only and assert
  # can_solve + the pinned origin-pull solver. Catches a dead corridor,
  # unpriceable amount, or rotated solver before any funds move.
  printf 'matrix preflight: quoting [%s] x [%s] read-only (no funds move)...\n' \
    "$XOCHI_LIVE_CORRIDORS" "$XOCHI_LIVE_TOKENS" >&2
  if ! env MIX_ENV=test mix test --only live_xochi_preflight \
      test/raxol/payments/xochi/live_xochi_test.exs; then
    printf 'matrix preflight FAILED: a cell cannot solve or the solver pin mismatched.\n' >&2
    printf 'No funds moved. Narrow XOCHI_LIVE_CORRIDORS / XOCHI_LIVE_TOKENS or fix the cell.\n' >&2
    exit 1
  fi

  if [[ -n "${DRY_RUN:-}" ]]; then
    printf 'DRY_RUN set: matrix preflight passed for every cell, NO funds moved.\n' >&2
    exit 0
  fi

  printf 'matrix mode: settling [%s] x [%s] x [%s] (REAL funds)...\n' \
    "$XOCHI_LIVE_CORRIDORS" "$XOCHI_LIVE_TOKENS" "$XOCHI_LIVE_SETTLEMENTS" >&2
  exec env MIX_ENV=test mix test --only live_xochi_matrix \
    test/raxol/payments/xochi/live_xochi_test.exs
fi

if [[ -n "${DRY_RUN:-}" ]]; then
  printf 'DRY_RUN set: auth + fill confirmed, NO funds moved.\n' >&2
  printf 're-run without DRY_RUN to submit the real mainnet intents.\n' >&2
  exit 0
fi

printf 'running the gate: this submits REAL mainnet intents and settles ~%s USDC per case...\n' \
  "$XOCHI_LIVE_AMOUNT" >&2
exec env MIX_ENV=test mix test --include live_xochi \
  test/raxol/payments/xochi/live_xochi_test.exs
