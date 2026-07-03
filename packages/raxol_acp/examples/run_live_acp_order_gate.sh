#!/usr/bin/env bash
# Order the xochi_cross_chain_transfer ACP offering and settle it for real.
#
# This is the end-to-end proof that another agent can ORDER our cross-chain
# settlement services through the ACP: a buyer creates a job, the seller's
# Raxol.ACP.Xochi.TransferOffering accepts it, and on delivery the real
# Raxol.ACP.Xochi.Settler runs Raxol.Payments.Protocols.Xochi.transfer (quote ->
# sign -> execute -> poll) against the Xochi worker + Riddler solver. The
# deliverable carries the intent id and the on-chain settlement tx hashes.
#
# The job orchestration uses the in-memory ContractClient (no live ACP escrow);
# the SETTLEMENT is real and MOVES FUNDS. Auth is the Member service token (the
# seller is a Xochi Member): the Settler uses one config for quote/execute/poll.
#
# USDC pulls via ERC-3009 and settles directly. USDT/WETH pull via Permit2 and
# need a standing on-chain allowance, which this gate broadcasts once per token
# per chain via Raxol.ACP.Onchain.Permit2Approver -- so each origin chain that
# carries a USDT/WETH cell needs an RPC URL in XOCHI_ORDER_RPC_<chain>. A
# USDT/WETH cell with no RPC for its origin chain is skipped (logged), not failed.
#
# The funded run settles only the FILLABLE SUBSET: it quotes each cell first and
# skips (logs) any the solver cannot fill right now.
#
# Usage (from packages/raxol_acp/):
#   # 1. Dry run: offering registration + read-only per-cell quote. NO funds move.
#   XOCHI_ORDER_LIVE_KEY=0x<funded> DRY_RUN=1 ./examples/run_live_acp_order_gate.sh
#
#   # 2. Real run: orders and settles (needs a funded seller key). USDC only:
#   XOCHI_ORDER_LIVE_KEY=0x<funded> XOCHI_ORDER_TOKENS=USDC \
#     ./examples/run_live_acp_order_gate.sh
#
#   # 3. All three tokens across the 6-chain mesh (USDT/WETH/USDG need per-chain RPC):
#   XOCHI_ORDER_LIVE_KEY=0x<funded> XOCHI_ORDER_CORRIDORS=mesh \
#   XOCHI_ORDER_TOKENS=USDC,USDT,WETH \
#   XOCHI_ORDER_RPC_8453=https://mainnet.base.org \
#   XOCHI_ORDER_RPC_42161=https://arb1.arbitrum.io/rpc \
#     ./examples/run_live_acp_order_gate.sh
#
#   # 4. A Robinhood-origin order (USDG->USDC cross-asset; USDG pulls via Permit2,
#   #    so the 4663 origin needs an RPC for the allowance broadcast):
#   XOCHI_ORDER_LIVE_KEY=0x<funded seller w/ USDG on 4663> \
#   XOCHI_ORDER_CORRIDORS=4663>8453 XOCHI_ORDER_TOKENS=USDC \
#   XOCHI_ORDER_RPC_4663=https://rpc.mainnet.chain.robinhood.com \
#     ./examples/run_live_acp_order_gate.sh
#
# The Member service token is a long-lived 1Password credential, per-env:
#   prod:    op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential (default)
#   staging: op://Employee/Xochi staging AGENT_SERVICE_TOKENS/credential
#
# Overrides: XOCHI_ORDER_LIVE_URL, XOCHI_ORDER_LIVE_TOKEN, OP_TOKEN_REF,
# XOCHI_ORDER_CORRIDORS ("from>to,from>to" or "mesh"), XOCHI_ORDER_TOKENS,
# XOCHI_ORDER_AMOUNT, XOCHI_ORDER_WETH_AMOUNT, XOCHI_ORDER_DESTINATION,
# XOCHI_ORDER_ALLOW_ETH_ORIGIN, XOCHI_ORDER_SOLVER, XOCHI_ORDER_SOLVER_PIN,
# XOCHI_ORDER_RPC_<chain>.
set -euo pipefail

XOCHI_ORDER_LIVE_URL="${XOCHI_ORDER_LIVE_URL:-https://api.xochi.fi}"
OP_TOKEN_REF="${OP_TOKEN_REF:-op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential}"
XOCHI_ORDER_TOKENS="${XOCHI_ORDER_TOKENS:-USDC,USDT,WETH}"
XOCHI_ORDER_CORRIDORS="${XOCHI_ORDER_CORRIDORS:-8453>42161}"

if [[ -z "${XOCHI_ORDER_LIVE_KEY:-}" ]]; then
  printf 'error: set XOCHI_ORDER_LIVE_KEY to a funded seller private key\n' >&2
  exit 1
fi

if [[ -z "${XOCHI_ORDER_LIVE_TOKEN:-}" ]]; then
  if ! command -v op >/dev/null 2>&1; then
    printf 'error: op CLI not found; set XOCHI_ORDER_LIVE_TOKEN directly\n' >&2
    exit 1
  fi
  printf 'reading Xochi worker token from 1Password (%s)...\n' "$OP_TOKEN_REF" >&2
  XOCHI_ORDER_LIVE_TOKEN="$(op read "$OP_TOKEN_REF")"
fi

export XOCHI_ORDER_LIVE_URL XOCHI_ORDER_LIVE_TOKEN XOCHI_ORDER_LIVE_KEY \
  XOCHI_ORDER_TOKENS XOCHI_ORDER_CORRIDORS

# Preflight: confirm the offering is registered and quote every cell read-only
# (can_solve + the pinned origin-pull solver). No funds move; this is all DRY_RUN
# runs. Aborts before any funded run if a cell serves the wrong solver.
printf 'preflight: offering discovery + read-only quotes for [%s] x [%s] (NO funds move)...\n' \
  "$XOCHI_ORDER_CORRIDORS" "$XOCHI_ORDER_TOKENS" >&2
if ! env MIX_ENV=test mix test --only live_xochi_order_preflight \
    test/raxol/acp/xochi/live_order_test.exs; then
  printf 'preflight FAILED: a cell served the wrong solver, or the offering is not registered.\n' >&2
  printf 'No funds moved. Fix the cell or narrow XOCHI_ORDER_CORRIDORS / XOCHI_ORDER_TOKENS.\n' >&2
  exit 1
fi

if [[ -n "${DRY_RUN:-}" ]]; then
  printf 'DRY_RUN set: preflight passed, NO funds moved.\n' >&2
  printf 're-run without DRY_RUN to place the real ACP order and settle.\n' >&2
  exit 0
fi

printf 'ordering through the ACP: this settles the fillable subset for REAL...\n' >&2
exec env MIX_ENV=test mix test --only live_xochi_order_settle \
  test/raxol/acp/xochi/live_order_test.exs
