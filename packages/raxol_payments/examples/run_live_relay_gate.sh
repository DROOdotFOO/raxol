#!/usr/bin/env bash
# Settle a full EVM->Tron transfer through the Relay rail (Riddler solver).
#
# A read-only /relay/quote probe validates the endpoint + token and moves no
# funds; under DRY_RUN that is all that runs. The real settlement broadcasts an
# on-chain ERC-20 deposit to the Riddler deposit address, so it needs the EVM tx
# stack that lives in raxol_acp: this gate runs the raxol_acp `:live_relay` test
# (ExecuteRelayTransfer -> OnchainBroadcaster -> PollRelayStatus), which moves
# REAL funds. Multiple source tokens settle in one run via RELAY_LIVE_TOKENS
# (each resolved per chain via Raxol.Payments.Assets); the destination is Tron.
#
# Usage (from packages/raxol_payments/):
#   # 1. Dry run: quote probe only, NO funds move, no key needed.
#   RELAY_LIVE_FROM_ADDRESS=0x<base address> DRY_RUN=1 ./examples/run_live_relay_gate.sh
#
#   # 2. Real settlement: broadcasts the deposit (needs a funded key + an RPC).
#   RELAY_LIVE_FROM_ADDRESS=0x<base address> \
#   RELAY_LIVE_KEY=0x<funded source-chain key> \
#   RELAY_LIVE_RPC=https://mainnet.base.org \
#   RELAY_LIVE_TOKENS=USDC,USDT \
#     ./examples/run_live_relay_gate.sh
#
# Override the endpoint or token source with RELAY_LIVE_URL / RELAY_LIVE_TOKEN.
# Corridor overrides: RELAY_LIVE_FROM_CHAIN, RELAY_LIVE_TOKENS,
# RELAY_LIVE_FROM_TOKEN (a raw origin address overriding the token list),
# RELAY_LIVE_TO_TOKEN, RELAY_LIVE_TO_ADDRESS, RELAY_LIVE_AMOUNT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACP_DIR="$SCRIPT_DIR/../../raxol_acp"

RELAY_LIVE_URL="${RELAY_LIVE_URL:-https://riddler.axol.io}"
# The /relay/* routes authenticate against TRON_RELAY_API_TOKEN, which
# ansible-riddler provisions from this 1Password item.
OP_TOKEN_REF="${OP_TOKEN_REF:-op://Employee/Riddler Tron Relay API Token/password}"
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

printf 'preflight: validating relay quote endpoint (read-only, no funds move)...\n' >&2
quote_body="$(printf '{"transfer_id":"probe","from_chain_id":8453,"to_chain_id":728126428,"from_token":"%s","to_token":"%s","from_amount":"%s","from_address":"%s","to_address":"%s","slippage_bps":50}' \
  "$RELAY_LIVE_FROM_TOKEN" "$RELAY_LIVE_TO_TOKEN" "$RELAY_LIVE_AMOUNT" "$RELAY_LIVE_FROM_ADDRESS" "$RELAY_LIVE_TO_ADDRESS")"

code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
  -X POST "$RELAY_LIVE_URL/relay/quote" \
  -H "authorization: Bearer $RELAY_LIVE_TOKEN" \
  -H 'content-type: application/json' \
  -d "$quote_body")"

if [[ "$code" != "200" ]]; then
  printf 'preflight FAILED: relay quote probe returned http %s. Fix the endpoint/token.\n' "$code" >&2
  printf 'No funds moved. Aborting.\n' >&2
  exit 1
fi

printf 'preflight ok: relay quote reachable (http 200).\n' >&2

if [[ -n "${DRY_RUN:-}" ]]; then
  printf 'DRY_RUN set: quote confirmed, NO funds moved.\n' >&2
  printf 're-run without DRY_RUN (with RELAY_LIVE_KEY + RELAY_LIVE_RPC) to settle.\n' >&2
  exit 0
fi

if [[ -z "${RELAY_LIVE_KEY:-}" || -z "${RELAY_LIVE_RPC:-}" ]]; then
  printf 'error: the real settlement broadcasts an on-chain deposit and needs\n' >&2
  printf 'RELAY_LIVE_KEY (funded source-chain key) and RELAY_LIVE_RPC (source-chain RPC).\n' >&2
  exit 1
fi

export RELAY_LIVE_URL RELAY_LIVE_TOKEN RELAY_LIVE_FROM_ADDRESS RELAY_LIVE_KEY RELAY_LIVE_RPC
export RELAY_LIVE_FROM_TOKEN RELAY_LIVE_TO_TOKEN RELAY_LIVE_TO_ADDRESS RELAY_LIVE_AMOUNT

# The full EVM->Tron settlement broadcasts the deposit, so it runs in raxol_acp
# (where the EIP-1559 signing / RLP / JSON-RPC stack lives).
printf 'settling EVM->Tron for REAL (broadcasts an on-chain deposit)...\n' >&2
cd "$ACP_DIR"
exec env MIX_ENV=test mix test --include live_relay \
  test/raxol/acp/relay/live_relay_test.exs
