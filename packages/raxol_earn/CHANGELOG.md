# Changelog

All notable changes to `raxol_earn` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - unreleased

First release. Elixir/OTP-native Agent Commerce Protocol seller and buyer for
the Virtuals marketplace, on the v2 hook/event model. Published from the
package formerly named `raxol_acp`; neither name has been on Hex before, so
0.2.0 is the first public version and there is no 0.1.x upgrade path.

### Added

- **Job session**: `Raxol.Earn.JobSession` plus
  `JobSession.{Registry, Supervisor, Status, Provider, HandlerSeam, Client, Tools}`.
  One supervised process per active job, registered by `{chain_id, job_id}`.
  A pure state machine over `:open -> :budget_set -> :funded -> :submitted ->
  :completed`, plus `:rejected` and `:expired`, with a chronological entry log,
  subscriber notifications, and a `[:raxol, :earn, :job_session, :transition]`
  telemetry event. `JobSession.Provider` is the seller-side driver: it invokes
  the offering handler, writes the on-chain hook call, then mirrors status via
  `apply_event/3`. The write is the commit point on purpose: a failed write
  leaves the session untouched.
- **Offerings**: `use Raxol.Earn.Offering` plus `Offering.{Handler, Registry}`,
  which registers a Job Offering on Virtuals. `mix earn.register_offering`
  emits the marketplace document.
- **On-chain writes**: `Raxol.Earn.HookClient` against `AgenticCommerceV3`
  through an injected `Raxol.Earn.ProviderAdapter`: `SCA` (sponsored
  ERC-4337 UserOps), `JSONRPC` (EOA, nonces serialized through `NonceServer`),
  `Privy` (signer sidecar), or `Mock`. `Raxol.Earn.Onchain.{RPC, Transaction, RLP}`
  are the EIP-1559 wire layer; ABIs are vendored under `priv/abi/` and verified
  Base addresses live in `Raxol.Earn.Chain`.
- **SCA wallet**: `Raxol.Earn.Wallet.SCA`, an ERC-4337 v0.7 / Alchemy Modular
  Account v2 stack (UserOp, bundler, paymaster, counterfactual CREATE2
  provisioning, session keys), self-deploying on the first transaction.
- **Seller runtime**: `Raxol.Earn.Seller.{Runtime, Queue, Supervisor, Resync}`
  with `Backend.{InMemory, WebSocket}`; the WebSocket backend speaks Socket.IO
  v4 / Engine.IO over `Mint.WebSocket`.
- **Buyer runtime**: `Raxol.Earn.Buyer.{Planner, Queue, Runtime, Resync,
  Supervisor}`. `Planner.buy/1` reserves budget, writes `createJob`, resolves
  the job id through the `JobIdResolver` seam (`Receipt` or `Mock`), and drives
  fund -> evaluate -> complete. Opt-in via `buyer_enabled: true`; the spend
  gate fails closed in production with no policy.
- **Crash recovery**: `JobSession.Provider` pins the encoded deliverable and
  its keccak in a `Raxol.Payments.Checkpoint` store before signing, and
  `Seller.Resync` drains `get_active_jobs` on boot and reconnect to re-drive
  interrupted jobs through the queue's idempotent dispatch. The guarantee is
  exactly-once-effective, at-least-once-attempted: one deliverable hash can
  exist per job, and a sign-then-crash replay resubmits that same hash, which
  the contract's phase guard reverts. Enable with `require_checkpoint: true`.
- **Xochi transfer offering** (`Raxol.Earn.Xochi.TransferOffering`): a pure
  storefront for cross-chain stablecoin transfers. The buyer quotes and signs
  the Xochi intent itself and puts the signed bundle in the job requirement;
  `Xochi.Settler` relays it on delivery. raxol never signs for or holds the
  transfer funds; the ACP budget is only the storefront fee (`:fee_bps`).
- **Launch liquidity gate**: `handle_request/2` accepts a job only for a
  corridor it can settle now, so a customer is refused before escrow rather
  than after a failed settlement. Backed by the live capability matrix,
  `:destination_caps`, `:closed_origins`, and a rolling aggregate reservation
  in `Xochi.CapacityLedger` (opt-in via `capacity_gate_enabled: true`).
  `mix raxol_earn.derive_caps` derives the config from the solver's on-chain
  balances; `Xochi.CapacityRefresher` keeps it current.
- **Console agent offering** (`Raxol.Earn.Console.AgentOffering`,
  `custom_console_agent`): sells a validated, deployment-ready Virtuals Console
  agent package as a plain job (`requiredFunds: false`). The deliverable is a
  `soul.md` + `tasks.json` package for Hermes or OpenClaw, statically validated
  and by default bench-validated on the real open-source runtime with the
  transcript shipped as evidence.
- **`Raxol.Earn.Auth`**: mints the Virtuals API JWT at boot from an EIP-712
  signature over the same provider adapter, so there is no separate API
  credential to manage.
- **Operator tasks**: `mix earn.register_offering`, `mix raxol_earn.order`,
  `mix raxol_earn.rebalance`, `mix raxol_earn.derive_caps`, and
  `mix raxol_earn.bench` (drives synthetic jobs through the seller stack).
- **Money-path telemetry** (ADR-0036) across the hook client, settlement, and
  spend-reporting paths.

### Changed

- **The v1 memo model is retired.** `ContractClient` / `ACPSimple` and the
  `:acp_version` switch are gone; the v2 hook/event model
  (`JobSession` + `HookClient` -> `AgenticCommerceV3`) is the only runtime.
  See `MIGRATION_V2.md`.

### Notes

- Pre-alpha. The public surface is unstable inside 0.x.
- Requires `raxol_payments` for wallet signing and Xochi settlement.
  `raxol_mcp` is a compile-time-only dependency for widget-tree-derived
  offering manifests.
- Going live is an operator procedure, not a library call: see `RUNBOOK.md`
  for the Base Sepolia dry-run and the mainnet promotion.
