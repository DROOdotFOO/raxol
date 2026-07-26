# raxol_payments examples

A guided path from a fully offline rehearsal to a real on-chain settlement. Each
script documents its own usage and environment in its header; this file is the
map and the recommended order.

Run everything from `packages/raxol_payments/`.

## 1. Rehearse the pay-stack (no funds, no network)

**`preflight.exs`** drives a single request through the whole stack: wallet ->
`SpendingPolicy` -> `Ledger` -> `AutoPay` -> `:on_confirm` -> `Req`, against the
local echo server. If the wiring does not fly here, it will not fly on mainnet.

```bash
mix raxol_payments.echo --port 4002      # terminal A: start the echo server
mix run examples/preflight.exs           # terminal B: run against it
```

## 2. Walk the launch path (no funds, in-process sim)

**`crosschain_stealth_payment.exs`** is the private cross-chain flow an agent
takes: issue a delegation mandate, execute a stealth Xochi intent (spend
authorized before signing), poll to settlement. Every step goes through the same
`Action.call/2` entry point the agent ReAct loop dispatches to, but against an
in-process Xochi sim, so it spends nothing.

```bash
MIX_ENV=test mix run examples/crosschain_stealth_payment.exs
```

## 3. Graduate to live (MOVES REAL FUNDS)

All four old per-package gates are consolidated into one launcher at the repo
root, `scripts/run_live_gates.sh`. It drives every asset (USDC, USDT, USDG)
across every route (xochi direct, acp order, relay to Tron) from a single
`--asset` / `--route` flag pair. Each cell runs a read-only preflight first and
aborts before moving funds if auth fails, the solver cannot fill, or a route is
dead. `--dry-run` runs preflight only. Run it from the repo root.

```bash
# rehearse the whole grid, no funds
GATE_FROM_ADDRESS=0x<addr> ./scripts/run_live_gates.sh --asset all --dry-run

# launch rail: real USDC across all three routes
GATE_KEY=0x<funded> GATE_FROM_ADDRESS=0x<addr> GATE_RPC_8453=https://mainnet.base.org \
  ./scripts/run_live_gates.sh --asset USDC

# just the ACP order path for USDC
GATE_KEY=0x<funded> ./scripts/run_live_gates.sh --asset USDC --route acp

# USDG drain (Robinhood 4663 -> Base USDC), dry-run first
GATE_KEY=0x<seller w/ USDG on 4663> GATE_RPC_4663=https://rpc.mainnet.chain.robinhood.com \
  ./scripts/run_live_gates.sh --asset USDG --route xochi,acp --dry-run
```

The gate fixes each asset's corridor and pull method to what Riddler and Xochi
support: USDC pulls via ERC-3009 across the CCTP mesh (Base to Arbitrum by
default); USDT pulls via Permit2 on the Arbitrum/Polygon corridors (not Base);
USDG is a Permit2 drain out of Robinhood Chain (4663 USDG to USDC on a hub).
USDT/USDG public launch is gated server-side on Riddler's verified-spender
Permit2 contract, so the gate prints a warning when either is selected. USDG has
no Tron leg, so `USDG --route relay` is skipped. Full flag and secret reference
is in the script header.

## The progression at a glance

| Stage            | Entrypoint                             | Funds | Target                     |
| ---------------- | -------------------------------------- | ----- | -------------------------- |
| Rehearse         | `preflight.exs`                        | none  | local echo server          |
| Launch path      | `crosschain_stealth_payment.exs`       | none  | in-process Xochi sim       |
| Live (all rails) | `scripts/run_live_gates.sh` (repo root) | real | Xochi worker + Riddler Relay |

The live gates are tagged `:live_xochi` / `:live_xochi_order` / `:live_relay` and
excluded by default; they only run when their endpoint env var is set (see each
package's `test/test_helper.exs`). For the architecture these examples exercise,
see [Agentic Commerce docs](../../../docs/features/AGENTIC_COMMERCE.md).
