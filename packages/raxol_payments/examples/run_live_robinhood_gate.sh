#!/usr/bin/env bash
# Run the live Xochi gate for the Base -> Robinhood Chain USDG corridor.
#
# This is a CROSS-ASSET corridor: the agent pays USDC on Base (chain 8453) and
# the recipient receives USDG (Global Dollar) on Robinhood Chain (chain 4663).
# The matrix mode of run_live_xochi_gate.sh resolves one token symbol on both
# chains, and Base has no USDG, so this corridor rides the single-corridor path
# with an explicit origin token (Base USDC, ERC-3009 gasless pull) and a distinct
# destination token (Robinhood USDG). Only the destination leg differs from the
# default Base->Arbitrum run: the agent-side origin pull and signing are identical,
# so this is the lowest-risk way to exercise Robinhood Chain end to end.
#
# Prerequisites:
#   1. Riddler/Xochi redeployed with chain 4663 + USDG registered (ansible-riddler:
#      COMMERCE_SOLVER_ROBINHOOD + ROBINHOOD_MAINNET_RPC_URL are wired there).
#   2. The solver funded with USDG on Robinhood Chain plus ETH for gas (the
#      canonical solver 0x97D447561fDe10E959E782a29411D8F89586d80b holds both).
#   3. XOCHI_LIVE_KEY: a funded Base mainnet key holding USDC (the origin leg).
#
# Rehearse first (quote-only, NO funds move; confirms auth + the corridor solves):
#   XOCHI_LIVE_KEY=0xdummy DRY_RUN=1 ./examples/run_live_robinhood_gate.sh
#
# Real run (submits mainnet intents; the test runs two cases, so it settles about
# 2x XOCHI_LIVE_AMOUNT of USDC origin, delivering the same in USDG):
#   XOCHI_LIVE_KEY=0x<funded base key> ./examples/run_live_robinhood_gate.sh
#
# Every override from run_live_xochi_gate.sh still applies (XOCHI_LIVE_AMOUNT,
# XOCHI_LIVE_AUTH, XOCHI_LIVE_SETTLEMENT, XOCHI_LIVE_URL, the solver pin, ...).
# The corridor endpoints below are themselves overridable if you point at a
# different origin token or a Robinhood-origin (4663 -> X) direction.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Base USDC (origin: 6 decimals, ERC-3009 gasless pull).
base_usdc="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
# Robinhood Chain USDG (destination: Global Dollar by Paxos, 6 decimals).
robinhood_usdg="0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"

export XOCHI_LIVE_FROM_CHAIN="${XOCHI_LIVE_FROM_CHAIN:-8453}"
export XOCHI_LIVE_TO_CHAIN="${XOCHI_LIVE_TO_CHAIN:-4663}"
export XOCHI_LIVE_FROM_TOKEN="${XOCHI_LIVE_FROM_TOKEN:-$base_usdc}"
export XOCHI_LIVE_TO_TOKEN="${XOCHI_LIVE_TO_TOKEN:-$robinhood_usdg}"

printf 'Robinhood corridor: %s USDC (Base %s) -> USDG (Robinhood Chain %s)\n' \
  "${XOCHI_LIVE_AMOUNT:-1.10}" "$XOCHI_LIVE_FROM_CHAIN" "$XOCHI_LIVE_TO_CHAIN" >&2

exec "$script_dir/run_live_xochi_gate.sh"
