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

These submit real mainnet intents. Each runs a read-only quote preflight first
and aborts before moving funds if auth fails or the solver cannot fill.

**`run_live_xochi_gate.sh`** settles cross-chain through the Xochi worker.
Defaults to a $1 Base -> Optimism USDC transfer (the corridor Xochi verified
fills at $1). Auth is a Member Bearer (the worker token in 1Password); one token
covers the whole quote -> execute -> poll lifecycle. Dry-run first:

```bash
XOCHI_LIVE_KEY=0x<funded base key> DRY_RUN=1 ./examples/run_live_xochi_gate.sh
XOCHI_LIVE_KEY=0x<funded base key>           ./examples/run_live_xochi_gate.sh
```

**`run_live_relay_gate.sh`** quotes the EVM->Tron Relay path through the Riddler
solver. A quote moves no funds, so it needs no key, just the staging token and a
source address. The full EVM->Tron settlement (which broadcasts an on-chain
deposit) lives in a separate raxol_acp `:live_relay` test.

```bash
RELAY_LIVE_FROM_ADDRESS=0x<base address> ./examples/run_live_relay_gate.sh
```

## The progression at a glance

| Stage            | Script                            | Funds         | Target                   |
| ---------------- | --------------------------------- | ------------- | ------------------------ |
| Rehearse         | `preflight.exs`                   | none          | local echo server        |
| Launch path      | `crosschain_stealth_payment.exs`  | none          | in-process Xochi sim     |
| Live cross-chain | `run_live_xochi_gate.sh`          | real          | Xochi worker (prod)      |
| Live Tron quote  | `run_live_relay_gate.sh`          | none (quote)  | Riddler solver (staging) |

The live gates are tagged `:live_xochi` / `:live_relay` and excluded by default;
they only run when their endpoint env var is set (see `test/test_helper.exs`).
For the architecture these examples exercise, see
[Agentic Commerce docs](../../../docs/features/AGENTIC_COMMERCE.md).
