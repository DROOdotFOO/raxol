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

Each gate runs a read-only preflight first and aborts before moving funds if auth
fails, the solver cannot fill, or a route is dead. Under `DRY_RUN` only the
preflight runs. Rehearse each with `DRY_RUN=1` before a funded run.

**`run_live_xochi_gate.sh`** settles cross-chain through the Xochi worker. In
matrix mode (`XOCHI_LIVE_MATRIX=true`) it validates the full 6-chain grid
(Ethereum, Optimism, Polygon, Base, Arbitrum with USDC/USDT/WETH; Robinhood
Chain with USDG/WETH):
the read-only preflight quotes every cell and asserts `can_solve`, the correct
pull method per token (USDC -> ERC-3009, USDT/WETH -> Permit2), and the pinned
Riddler solver; the funded run settles only the fillable subset. USDC settles
here directly; USDT/WETH need a standing Permit2 allowance, so their real
settlement is the ACP order gate below (or opt in with `XOCHI_LIVE_SETTLE_PERMIT2=true`
once the allowance is set). Auth defaults to a self-signed mandate; `member` uses
the worker token in 1Password.

```bash
# full 5x3 grid, read-only (no funds)
XOCHI_LIVE_KEY=0x<funded> DRY_RUN=1 XOCHI_LIVE_MATRIX=true \
  XOCHI_LIVE_CORRIDORS=mesh XOCHI_LIVE_TOKENS=USDC,USDT,WETH \
  ./examples/run_live_xochi_gate.sh
# settle the fillable USDC subset for real
XOCHI_LIVE_KEY=0x<funded> XOCHI_LIVE_MATRIX=true \
  XOCHI_LIVE_CORRIDORS=mesh XOCHI_LIVE_TOKENS=USDC ./examples/run_live_xochi_gate.sh
```

**`run_live_robinhood_gate.sh`** settles the Base -> Robinhood Chain USDG
corridor. This one is cross-asset: the agent pays USDC on Base and the recipient
receives USDG (Global Dollar) on Robinhood Chain (4663). Base has no USDG, so it
uses the single-corridor path with an explicit origin token (Base USDC, ERC-3009)
and destination token (Robinhood USDG); only the destination leg differs from the
default Base->Arbitrum run. Needs Riddler/Xochi redeployed with 4663 + USDG and
the solver funded with USDG on Robinhood Chain.

```bash
# quote-only, no funds
XOCHI_LIVE_KEY=0xdummy DRY_RUN=1 ./examples/run_live_robinhood_gate.sh
# real settlement (funded Base USDC key)
XOCHI_LIVE_KEY=0x<funded base key> ./examples/run_live_robinhood_gate.sh
```

**`../../raxol_acp/examples/run_live_acp_order_gate.sh`** is the proof another
agent can ORDER these settlements through the ACP: a buyer creates a job for the
`xochi_cross_chain_transfer` offering and the seller settles it via Xochi for
real. It sets the Permit2 allowance for USDT/WETH first (needs
`XOCHI_ORDER_RPC_<chain>`), then settles the fillable subset across USDC/USDT/WETH.

```bash
XOCHI_ORDER_LIVE_KEY=0x<funded> DRY_RUN=1 ./run_live_acp_order_gate.sh
XOCHI_ORDER_LIVE_KEY=0x<funded> XOCHI_ORDER_RPC_8453=https://mainnet.base.org \
  XOCHI_ORDER_TOKENS=USDC,USDT,WETH ./run_live_acp_order_gate.sh
```

**`run_live_relay_gate.sh`** settles a full EVM->Tron transfer through the
Riddler Relay rail. A read-only `/relay/quote` probe runs first (all `DRY_RUN`
runs); the real settlement broadcasts the on-chain deposit via the raxol_acp
`:live_relay` test, so it needs a funded key and a source-chain RPC. Multiple
source tokens settle via `RELAY_LIVE_TOKENS`.

```bash
RELAY_LIVE_FROM_ADDRESS=0x<base address> DRY_RUN=1 ./examples/run_live_relay_gate.sh
RELAY_LIVE_FROM_ADDRESS=0x<base address> RELAY_LIVE_KEY=0x<funded> \
  RELAY_LIVE_RPC=https://mainnet.base.org ./examples/run_live_relay_gate.sh
```

## The progression at a glance

| Stage            | Script                            | Funds         | Target                    |
| ---------------- | --------------------------------- | ------------- | ------------------------- |
| Rehearse         | `preflight.exs`                   | none          | local echo server         |
| Launch path      | `crosschain_stealth_payment.exs`  | none          | in-process Xochi sim      |
| Live cross-chain | `run_live_xochi_gate.sh`          | real          | Xochi worker (6 chains)   |
| Live Robinhood   | `run_live_robinhood_gate.sh`      | real          | Base USDC -> RH USDG      |
| Live ACP order   | `run_live_acp_order_gate.sh`      | real          | ACP job -> Xochi worker   |
| Live Tron settle | `run_live_relay_gate.sh`          | real          | Riddler Relay (Tron)      |

The live gates are tagged `:live_xochi` / `:live_xochi_order` / `:live_relay` and
excluded by default; they only run when their endpoint env var is set (see each
package's `test/test_helper.exs`). For the architecture these examples exercise,
see [Agentic Commerce docs](../../../docs/features/AGENTIC_COMMERCE.md).
