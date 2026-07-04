# raxol_acp

Elixir/OTP-native Agent Commerce Protocol (ACP) implementation for the
[Virtuals](https://app.virtuals.io) agent marketplace.

> Status: pre-alpha. Public surface is unstable. Targeting v0.1 with a
> single graduated offering on Base mainnet.

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
    {:raxol_acp, "~> 0.1"}
  ]
end
```

The package self-starts via its OTP application entry. Add it to your deps,
run `mix deps.get`, and `Raxol.ACP.Supervisor` boots automatically.

## Architecture

See `Raxol.ACP.Supervisor` for the supervision tree. Subsystems:

- **Job lifecycle**: `Raxol.ACP.Job.{Server, Supervisor, Registry, StateMachine, Store}`. One `:gen_server` per active job, registered by job ID, with ETS-backed memo persistence so a node restart resumes mid-flight. States are `:request -> :negotiation -> :transaction -> :evaluation -> :completed` plus `:rejected` and `:expired`. Memos are on-chain `createMemo` calls (no off-chain signing); `Job.MemoType`/`Job.FeeType` are the canonical enums.
- **Offering**: `Raxol.ACP.Offering.{Handler, Registry, DSL}`. Define an offering with `use Raxol.ACP.Offering`; it becomes a registered Job Offering on Virtuals.
- **Contract client**: `Raxol.ACP.ContractClient` behaviour matching the real `ACPSimple` (V1) / `ACPRouter` (V2) write surface, switched via `:acp_version`. Includes `withdraw_escrowed_funds` for buyer escrow reclaim after non-delivery (paired with a `Job.Server` `:expired_at` auto-expire timer and `Job.Server.reclaim/1`). Two impls: `InMemory` (tests) and `Onchain` (Req JSON-RPC + EIP-1559 typed-tx). `Onchain.create_job` resolves the job id from the `JobCreated` non-indexed `data` word and fails closed on an unresolved id; a lost receipt returns `{:receipt_pending, tx_hash, _}` and a pre-broadcast failure rolls the nonce back. Real ABIs vendored under `priv/abi/`; verified Base addresses in `Raxol.ACP.Chain`.
- **SCA wallet**: `Raxol.ACP.Wallet.SCA` is a full ERC-4337 v0.7 / Alchemy Modular Account v2 stack (UserOp, bundler, paymaster, counterfactual CREATE2 provisioning, session keys). `Onchain` detects an SCA wallet and routes writes through sponsored UserOps, self-deploying on the first tx. Live-validated against the real on-chain EntryPoint on a Base fork.
- **Seller runtime**: `Raxol.ACP.Seller.{Runtime, Queue, Supervisor}` plus `Backend.{InMemory, WebSocket}`. The WebSocket backend speaks Socket.IO v4 / Engine.IO over `Mint.WebSocket`; the runtime dispatches incoming jobs to the queue.

## First offering: Xochi Cross-Chain Transfer

`Raxol.ACP.Xochi.TransferOffering` sells cross-chain stablecoin transfers as a **pure storefront**. The buyer quotes and signs a Xochi intent themselves (`Raxol.Payments.Protocols.Xochi.quote_and_sign/3`) and puts the signed bundle in the job requirement; on delivery `Raxol.ACP.Xochi.Settler` relays it to Xochi via `execute_signed/2` and returns the settlement tx hashes. raxol never signs or holds the transfer funds. The transfer settles off-escrow through Xochi; the ACP budget is only raxol's storefront fee (8 bps of the transfer, via `:fee_bps`). See `examples/buyer_signed_intent.exs`.

## Dependencies

- `raxol_payments` for wallet signing (`Raxol.Payments.EIP712`, `Raxol.Payments.Wallet`) and Xochi cross-chain settlement
- `raxol_mcp` (compile-time only, `runtime: false`) for v0.2 widget-tree-derived offering manifests

## License

MIT. See `LICENSE.md`.
