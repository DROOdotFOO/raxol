# Migrating raxol_earn from v1 to v2

`raxol_earn` was originally written against `@virtuals-protocol/acp-node@0.3.0-beta.40`. Virtuals deprecated that SDK on **2026-06-01** in favor of [`@virtuals-protocol/acp-node-v2`](https://github.com/Virtual-Protocol/acp-node-v2). The protocol layer changed substantially:

- Memo-based job model → **hook-based** model (`FundTransferHook`, `SubscriptionHook`, `MultiHookRouter`).
- Phase-callback API (`onNewTask`, `onEvaluate`) → **event-driven** API (`on("entry", handler)`).
- Phase enum `request/negotiation/transaction/evaluation/completed` → `open/budget_set/funded/submitted/completed/rejected/expired`.
- Socket.IO transport → **SSE** primary (`api.acp.virtuals.io`), Socket.IO legacy.
- `Fare`/`FareAmount` token type → **`AssetToken`**.
- Implicit settlement on phase transition → **explicit `complete()` / `reject()`**.
- Raw private keys → **Privy + Alchemy ERC-4337**.
- Compliance with **ERC-8183 (Agentic Commerce)**.

`raxol_earn` 0.2.0 replaces the v1 surface with the v2 surface in place. The seller-stack migration (Phases 1-4) is complete: the memo/`Job.Server` model is gone and every path runs on the v2 `JobSession` + hook model. This document tracks what landed and what's still pending.

## Status — 2026-07-07

| Area | v1 (removed) | v2 status |
|------|---------------|-----------|
| Chain config | `Raxol.Earn.Chain` (`acp_contract_address`, `acp_router_address`) | **Done** — adds `acp_core_address` + hook/router/subscription addresses + `acp_server_url`. The legacy addresses stay only for indexer/dashboard back-compat. |
| Token amounts | `Fare`/`FareAmount` (Decimal-based) | **Done** — `Raxol.Earn.AssetToken` (raw integer + decimals + chain-aware) |
| Event model | `onNewTask`/`onEvaluate` via Socket.IO | **Done** — `Raxol.Earn.Event`, SSE transport (`transport/sse/parser.ex`), `Raxol.Earn.Agent` event dispatch |
| Job session | `Raxol.Earn.Job.Server` (memo/phase model) — **removed** | **Done** — `Raxol.Earn.JobSession` (event/hook model) is the only session runtime. The seller `Queue`/`Runtime`/`bench` drive it via `Raxol.Earn.JobSession.Provider`. |
| On-chain writes | `Raxol.Earn.ContractClient` + `Onchain` (memo `createMemo`/`createJob` JSON-RPC) — **removed** | **Done** — `Raxol.Earn.HookClient` → `AgenticCommerceV3` via `Raxol.Earn.ProviderAdapter` (`SCA` sponsored UserOps or `JSONRPC` EOA) |
| Hook integration | (no first-class hooks) | **Done** — `Raxol.Earn.Hooks.FundTransfer` (note: the storefront relay offering runs plain jobs, `hook = address(0)`) |
| Xochi offering | (none) | **Done** — `Raxol.Earn.Xochi.Offering` + `Raxol.Earn.Xochi.SolverAgent` runtime (8bps storefront fee) |
| Wallet/signer | `Raxol.Earn.Wallet.SCA` (MAv2 + session keys) | **Done** — two-userOp v2 provisioning (`Wallet.SCA.Provisioner`: deploy + install as separate userOps) |
| Marketplace registration | — | **Done** — `mix earn.register_offering` |

## The v1 seller-stack retirement (Phases 1-4, landed 2026-07-07)

The memo/`Job.Server` model was removed in four steps:

1. **Phase 1** — `Raxol.Earn.JobSession.Provider` driver, the seam that lets the
   seller stack drive a v2 `JobSession` with the same call surface the Queue used.
2. **Phase 2** — re-pointed `Raxol.Earn.Seller.Queue` off `Job.Server` onto
   `JobSession.Provider`.
3. **Phase 3** — migrated `mix raxol_earn.bench` and **deleted the v1
   `Job.Server` lifecycle** (`Job.Server`, `Job.Supervisor`, their tests).
4. **Phase 4** — retired the now-unused memo write path: `Raxol.Earn.ContractClient`
   (behaviour + `Onchain` + `InMemory`), the `Raxol.Earn.Directive` memo/job
   directives + their `Directive.Executor` impls, the `Job.MemoType` / `Job.FeeType`
   enums, `Job.StateMachine` (replaced by `JobSession.Status`), `Onchain.LogDecoder`,
   and the unused `Job.Store`. The `ACP_VERSION` / `:acp_version` switch is gone
   with `ContractClient.Onchain` — the active core (`AgenticCommerceV3` via
   `HookClient`) never consulted it. Chain kept the legacy addresses for indexer
   back-compat.

The one cross-package consumer, `raxol_symphony`'s ACP auto-resume, was migrated
to the v2 `[:raxol, :earn, :job_session, :transition]` telemetry in the same PR.

## Still pending (funds-gated)

- Staging-validate the active v2 (`AgenticCommerceV3`) lifecycle end-to-end
  against a Base fork/staging (needs funds).
- Graduate `xochi_cross_chain_transfer` on Base mainnet.
- The SCA `:live_bundler` end-to-end + SolverAgent-vs-staging run.

## Strategy

We replaced v1 in place inside this single package, NOT by spinning up
`raxol_acp_v2`. The mix version reflects the state: `0.2.0-pre.0` while
scaffolding, **`0.2.0-rc.0` now** that the v2 surface is feature-complete and v1
is removed; `0.2.0` final once the funds-gated staging validation above passes.

## Why not Privy?

`acp-node-v2` standardizes on `PrivyAlchemyEvmProviderAdapter` for non-custodial key storage (P256 keys in OS keychain). Adopting Privy in Elixir would require either (a) calling a Privy HTTP wrapper from BEAM, or (b) reimplementing Privy's signing protocol natively. Neither is justified for our use case: we already run a BEAM-native MAv2 SCA wallet with Alchemy paymaster + session keys, and the Xochi solver agent is server-side (not a user-facing app where OS keychain matters). The Elixir-native `ProviderAdapter.SCA` keeps everything in process and avoids a third-party runtime dep.

## References

- [acp-node-v2 README](https://github.com/Virtual-Protocol/acp-node-v2/blob/main/README.md)
- [acp-node-v2 migration guide](https://github.com/Virtual-Protocol/acp-node-v2/blob/main/migration.md)
- [Virtuals whitepaper, ACP v2 section](https://whitepaper.virtuals.io/llms-full.txt)
- [ERC-8183 Agentic Commerce](https://ethereum-magicians.org/t/erc-8183-agentic-commerce/27902)
