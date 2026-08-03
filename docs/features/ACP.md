# Agent Commerce Protocol (ACP)

`raxol_earn` is an Elixir/OTP implementation of the [Virtuals ACP](https://www.virtuals.io/) for selling agent services on Base. Where `raxol_payments` is about *paying* (an agent that buys things), `raxol_earn` is about *being paid* (an agent that offers a service and accepts on-chain settlement).

Status: pre-alpha. Not yet on Hex; use the path dep at `packages/raxol_earn/`.

> **Two protocols share the letters "ACP".** This page is the **Agent Commerce Protocol**
> (`Raxol.Earn`, on-chain payments for selling agent services). It is unrelated to the
> [Editor Agent Client Protocol](EDITOR_ACP.md) (`Raxol.AgentClientProtocol`, the JSON-RPC
> protocol between a code editor and an AI coding agent). Different acronym expansion,
> different domain.

## Job Lifecycle

Every job is a state machine. One supervised `Raxol.Earn.JobSession` runs per active job, registered by `{chain_id, job_id}`:

```
:open -> :budget_set -> :funded -> :submitted -> :completed
                                            \-> :rejected
(any non-terminal) -> :expired
```

`Raxol.Earn.JobSession.Status` is a pure module holding the status enum and the legal transition graph. `JobSession` is the GenServer: it tracks role-aware status, keeps a chronological entry log, notifies subscribers, and emits `[:raxol, :earn, :job_session, :transition]` telemetry on every change. `apply_event/3` applies an OBSERVED status (an on-chain or SSE event) directly, bypassing role and adjacency gating.

```elixir
{:ok, _pid} =
  Raxol.Earn.JobSession.Supervisor.start_session(
    chain_id: 8453,
    job_id: "job-42",
    role: :provider
  )

# Provider actions transition the session; the Provider driver (below)
# pairs each with the matching hook write on-chain.
{:ok, :budget_set} = Raxol.Earn.JobSession.set_budget({8453, "job-42"}, budget)
{:ok, :submitted} = Raxol.Earn.JobSession.submit({8453, "job-42"}, deliverable)
```

The seller-side glue is `Raxol.Earn.JobSession.Provider`: for each lifecycle step it invokes the offering `Handler` (via `JobSession.HandlerSeam`), writes the hook call on-chain through `HookClient` + `ProviderAdapter` (the commit point -- a failed write leaves the session untouched), then mirrors the resulting status with `apply_event/3`.

## Offerings

An offering is a service the agent sells. Declared via the `Offering` DSL:

```elixir
defmodule Raxol.Earn.Offerings.SentimentAnalysis do
  use Raxol.Earn.Offering,
    name: "Sentiment Analysis",
    price_usdc: 10,
    sla_minutes: 5,
    cluster: "analytics"

  # Decide whether to take the job. Return {:accept, response} to accept
  # and set the budget, or {:reject, reason} to bow out.
  @impl true
  def handle_request(request, _ctx) do
    {:accept, %{quoted_usdc: 10, text: request.text}}
  end

  # Payment is escrowed; produce the deliverable.
  @impl true
  def handle_deliver(request, _ctx) do
    {:deliver, %{sentiment: analyze(request.text)}}
  end
end
```

The DSL injects the `Handler` behaviour and registers metadata in the ETS-backed `Registry`. `JobSession.Provider` invokes the handler at each lifecycle step and writes the matching hook call on-chain with the configured wallet.

## Xochi Cross-Chain Transfer (the first offering)

`Raxol.Earn.Xochi.TransferOffering` is the first offering: a **pure storefront** for cross-chain stablecoin transfers. raxol never signs or holds the buyer's funds.

- The buyer quotes and signs a Xochi intent themselves (`Raxol.Payments.Protocols.Xochi.quote_and_sign/3`) and puts the signed bundle in the job requirement's `signed_intent`.
- On delivery, `Raxol.Earn.Xochi.Settler` relays that bundle to Xochi via `execute_signed/2` (no re-signing) and polls it to settlement; the deliverable is the on-chain settlement tx hashes.
- The transfer settles through Xochi off-escrow, so the ACP core's take never bites it. The job is a **plain job** (`hook = address(0)`); the ACP budget is only raxol's storefront fee -- **8 bps of the transfer**, set via `:fee_bps`. On completion the provider nets `budget * 0.90`.

`packages/raxol_earn/examples/buyer_signed_intent.exs` shows the buyer flow and the requirement/deliverable schemas to register on the marketplace.

## Launch liquidity gate

`TransferOffering.handle_request/2` accepts a job only for a corridor it can settle now, so a customer gets a clean rejection **before escrow** rather than an accept that fails at settlement. Four layers, all config-driven and inert by default:

- **Corridor support**: the live `Raxol.Payments.Xochi.Capabilities` matrix (which chains/tokens the solver fills), degrading to the static `Raxol.Payments.Assets` set when the endpoint is unreachable.
- **Per-order caps** (`config :raxol_earn, :destination_caps`): a max order size per destination `{chain, token_address}`; `0` closes the corridor. Rejects `{:over_capacity, chain, token}`.
- **Closed origins** (`config :raxol_earn, :closed_origins`): src chains to refuse outright (e.g. Robinhood while the USDG exit is down). Rejects `{:origin_closed, chain}`.
- **Rolling aggregate**: `Raxol.Earn.Xochi.CapacityLedger` bounds the *running total* committed per destination across concurrent jobs: reserve at accept, confirm at settle, release on failure, TTL-sweep if a job never settles. Opt-in via `capacity_gate_enabled: true`, which adds `Raxol.Earn.Xochi.CapacityGate` (the ledger + a periodic `CapacityRefresher`) to the seller tree.

`mix raxol_earn.derive_caps` reads the solver's live `balanceOf` per corridor and emits both maps (`--order-frac`/`--aggregate-frac`/`--min-usd`, per-chain RPC via `DERIVE_RPC_<chain>`). The `CapacityRefresher` runs the same reads on an interval, so aggregate capacity tracks the chain as fills drain inventory. Starting point in `packages/raxol_earn/config/destination_caps.example.exs`.

## On-Chain Writes

The v2 model writes **hook calls** to the active `AgenticCommerceV3` core; there is no separate memo model (the v1 `createMemo` / `Raxol.Earn.ContractClient` write surface and the `:acp_version` switch were retired -- see `MIGRATION_V2.md`). `Raxol.Earn.HookClient` exposes `set_budget` / `submit` / `complete` / `reject`, each dispatched through an injected `Raxol.Earn.ProviderAdapter`:

- `SCA`: sponsored ERC-4337 v0.7 UserOps via `Raxol.Earn.Wallet.SCA` (Alchemy Modular Account v2 + paymaster). Self-deploys the account on the first write.
- `JSONRPC`: a plain EOA signing EIP-1559 typed transactions (`Raxol.Earn.Onchain.{RPC, Transaction, RLP}`), with nonce assignment serialized through `Raxol.Earn.Wallet.NonceServer`.
- `Mock`: in-process, for tests and `mix raxol_earn.bench`.

`Raxol.Earn.ABI` hand-rolls the Solidity encoder for the ACP methods. Real ABIs are vendored under `priv/abi/`; verified Base addresses live in `Raxol.Earn.Chain` (the active `acp_core_address` plus the hook/router/subscription addresses; the legacy `acp_contract_address`/`acp_router_address` remain only for indexer back-compat).

## Expiry

`JobSession` reaches the terminal `:expired` status via `expire/2` from any non-terminal status, so a job whose counterparty abandoned it can be closed rather than left wedged. `:expired`, `:completed`, and `:rejected` are terminal -- the session process stops with `:normal` once it reaches one. On-chain escrow handling on expiry is the `AgenticCommerceV3` core's responsibility.

## Nonce Serialization

The `Raxol.Earn.Wallet.NonceServer` GenServer serializes EVM nonce assignment through its mailbox, so two concurrent EOA writes from one wallet can never sign the same nonce. `ProviderAdapter.JSONRPC` routes every send through it. A send that fails before broadcast resyncs the counter, so the next send re-fetches the pending nonce from chain and re-fills the gap rather than leaving a hole that would strand every later transaction. The SCA/UserOp path uses ERC-4337 EntryPoint nonces and is unaffected.

## Seller Stack

Opt-in via `:seller_enabled` in config:

- `Backend.InMemory`: in-process request queue (default)
- `Queue`: bounded mailbox, backpressure
- `Runtime`: worker pool dispatching to handlers
- `Supervisor`: ties it all together

`Backend.WebSocket` (Socket.IO v4 / Engine.IO over `Mint.WebSocket`, talking to Virtuals' relayer) is implemented alongside `Backend.InMemory`; the `Queue` drives `JobSession.Provider`. The protocol spec is available via the `virtuals-protocol-acp` skill.

## Status

Pre-alpha, not yet on Hex. The `Wallet.SCA` ERC-4337 stack, the real vendored ABIs (`priv/abi/`), and the `Backend.WebSocket` Socket.IO client are implemented; the on-chain paths are fork-validated against the real deployed core on Base. `mix raxol_earn.bench` runs end-to-end against the InMemory backend.

## See Also

- [Agentic Commerce](AGENTIC_COMMERCE.md): the buyer side (raxol_payments)
- [Agent Framework](AGENT_FRAMEWORK.md): the runtime hosting the seller
