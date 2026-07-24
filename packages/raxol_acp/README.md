# raxol_acp

Elixir/OTP-native Agent Commerce Protocol (ACP) implementation for the
[Virtuals](https://app.virtuals.io) agent marketplace.

> Status: pre-alpha (`0.2.0-rc.0`). Public surface is unstable. The v1 memo
> model has been retired; the v2 hook/event model (`JobSession` + `HookClient`
> -> `AgenticCommerceV3`) is the active runtime. Targeting a single graduated
> offering on Base mainnet.

## Why OTP for ACP

Every other ACP seller is a Python or Node script wrapped around a WebSocket,
with hand-rolled `threading.Lock` for concurrent jobs and a polling loop for
flaky sockets. OTP solves both at the runtime layer:

| ACP runtime requirement       | Other SDKs                | raxol_acp                                     |
| ----------------------------- | ------------------------- | --------------------------------------------- |
| Concurrent job handling       | Thread-safe queue + locks | One supervised process per job                |
| Reconnect on socket drop      | Polling fallback          | Supervisor with backoff                       |
| One agent, many offerings     | Single fragile process    | Process-per-offering, crash isolation         |
| Hot-fix a buggy offering      | Redeploy, drop sockets    | Hot code reload                               |
| Wallet nonce serialization    | Best-effort retries       | Dedicated `NonceServer` GenServer per wallet  |

## Installation

```elixir
def deps do
  [
    {:raxol_acp, "~> 0.2-rc"}
  ]
end
```

The package self-starts via its OTP application entry. Add it to your deps,
run `mix deps.get`, and `Raxol.ACP.Supervisor` boots automatically.

## Architecture

See `Raxol.ACP.Supervisor` for the supervision tree. Subsystems:

- **Job session**: `Raxol.ACP.JobSession` + `JobSession.{Registry, Supervisor, Status, Provider, HandlerSeam}`. One supervised process per active job, registered by `{chain_id, job_id}`. It is a pure state machine -- role-aware status, a chronological entry log, subscriber notifications, and a `[:raxol, :acp, :job_session, :transition]` telemetry event. Statuses are `:open -> :budget_set -> :funded -> :submitted -> :completed` plus `:rejected` and `:expired`. `JobSession.Provider` is the seller-side driver: it invokes the offering `Handler`, writes the on-chain hook call (the commit point -- a failed write leaves the session untouched), then mirrors the status via `apply_event/3`.
- **Offering**: `Raxol.ACP.Offering.{Handler, Registry, DSL}`. Define an offering with `use Raxol.ACP.Offering`; it becomes a registered Job Offering on Virtuals.
- **On-chain writes**: `Raxol.ACP.HookClient` writes to the active `AgenticCommerceV3` core through an injected `Raxol.ACP.ProviderAdapter` -- `SCA` (sponsored ERC-4337 UserOps), `JSONRPC` (EOA, nonce serialized through `NonceServer`), or `Mock` (tests). `Raxol.ACP.Onchain.{RPC, Transaction, RLP}` are the EIP-1559 wire layer. Real ABIs vendored under `priv/abi/`; verified Base addresses in `Raxol.ACP.Chain`. (The v1 `ContractClient` / `ACPSimple` memo write surface and the `:acp_version` switch were retired -- see `MIGRATION_V2.md`.)
- **SCA wallet**: `Raxol.ACP.Wallet.SCA` is a full ERC-4337 v0.7 / Alchemy Modular Account v2 stack (UserOp, bundler, paymaster, counterfactual CREATE2 provisioning, session keys). `Raxol.ACP.ProviderAdapter.SCA` detects an SCA wallet and routes writes through sponsored UserOps, self-deploying on the first tx. Live-validated against the real on-chain EntryPoint on a Base fork.
- **Seller runtime**: `Raxol.ACP.Seller.{Runtime, Queue, Supervisor}` plus `Backend.{InMemory, WebSocket}`. The WebSocket backend speaks Socket.IO v4 / Engine.IO over `Mint.WebSocket`; the runtime dispatches incoming jobs to the queue.

## First offering: Xochi Cross-Chain Transfer

`Raxol.ACP.Xochi.TransferOffering` sells cross-chain stablecoin transfers as a **pure storefront**. The buyer quotes and signs a Xochi intent themselves (`Raxol.Payments.Protocols.Xochi.quote_and_sign/3`) and puts the signed bundle in the job requirement; on delivery `Raxol.ACP.Xochi.Settler` relays it to Xochi via `execute_signed/2` and returns the settlement tx hashes. raxol never signs or holds the transfer funds. The transfer settles off-escrow through Xochi; the ACP budget is only raxol's storefront fee (8 bps of the transfer, via `:fee_bps`). See `examples/buyer_signed_intent.exs`.

### Launch liquidity gate

`handle_request/2` accepts a job only for a corridor it can settle now, so a customer is rejected before escrow rather than after a failed settlement: the live capability matrix, per-order caps (`:destination_caps`), closed origins (`:closed_origins`), and a rolling aggregate reservation (`Raxol.ACP.Xochi.CapacityLedger`, opt-in via `capacity_gate_enabled: true`). `mix raxol_acp.derive_caps` derives the config from the solver's on-chain balances and `Raxol.ACP.Xochi.CapacityRefresher` refreshes it periodically. See `config/destination_caps.example.exs` and `docs/features/ACP.md`.

## Second offering: Custom Console Agent

`Raxol.ACP.Console.AgentOffering` (`custom_console_agent`) sells a validated, deployment-ready Virtuals Console agent package as a **plain job** (`requiredFunds: false`, no escrowed principal, no corridor liquidity). The buyer sends a spec (purpose, runtime, persona, scheduled tasks, skills); the deliverable is a `soul.md` + `tasks.json` (+ `AGENTS.md`, `skills/`) package for **Hermes** or **OpenClaw**, statically validated and -- by default -- bench-validated on the actual open-source runtime with the transcript shipped as evidence. Generation runs on wallet-funded Virtuals compute.

Crash-recovery (M1) is wired end to end: `JobSession.Provider` pins the encoded deliverable + keccak in a `Raxol.Payments.Checkpoint` store **before** signing, and `Raxol.ACP.Seller.Resync` drains `get_active_jobs` on boot/reconnect and re-drives interrupted jobs through the Queue's idempotent dispatch, so a BEAM restart resumes rather than double-submitting (**exactly-once-effective, at-least-once-attempted**). Enable with `require_checkpoint: true` in production.

Config surface: `config/console_offering.example.exs`. Base Sepolia go-live: `RUNBOOK.md`. Emit the marketplace document with `mix acp.register_offering --offering console`.

## Dependencies

- `raxol_payments` for wallet signing (`Raxol.Payments.EIP712`, `Raxol.Payments.Wallet`) and Xochi cross-chain settlement
- `raxol_mcp` (compile-time only, `runtime: false`) for v0.2 widget-tree-derived offering manifests

## License

MIT. See `LICENSE.md`.
