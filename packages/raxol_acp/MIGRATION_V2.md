# Migrating raxol_acp from v1 to v2

`raxol_acp` was originally written against `@virtuals-protocol/acp-node@0.3.0-beta.40`. Virtuals deprecated that SDK on **2026-06-01** in favor of [`@virtuals-protocol/acp-node-v2`](https://github.com/Virtual-Protocol/acp-node-v2). The protocol layer changed substantially:

- Memo-based job model → **hook-based** model (`FundTransferHook`, `SubscriptionHook`, `MultiHookRouter`).
- Phase-callback API (`onNewTask`, `onEvaluate`) → **event-driven** API (`on("entry", handler)`).
- Phase enum `request/negotiation/transaction/evaluation/completed` → `open/budget_set/funded/submitted/completed/rejected/expired`.
- Socket.IO transport → **SSE** primary (`api.acp.virtuals.io`), Socket.IO legacy.
- `Fare`/`FareAmount` token type → **`AssetToken`**.
- Implicit settlement on phase transition → **explicit `complete()` / `reject()`**.
- Raw private keys → **Privy + Alchemy ERC-4337**.
- Compliance with **ERC-8183 (Agentic Commerce)**.

`raxol_acp` 0.2.0 ships the v2 surface alongside the v1 surface so existing solver code keeps working during the transition. This document tracks what's landed and what's still pending.

## Status — 2026-06-13

| Area | v1 (existing) | v2 (scaffolded this PR) | v2 (TODO) |
|------|---------------|-------------------------|-----------|
| Chain config | `Raxol.ACP.Chain` (mainnet, sepolia, `acp_contract_address`, `acp_router_address`) | adds `acp_core_address`, `fund_transfer_hook_address`, `multi_hook_router_address`, `subscription_hook_address`, `subscription_state_address`, `acp_server_url` | — |
| Token amounts | `Fare`/`FareAmount` (Decimal-based) | `Raxol.ACP.AssetToken` (raw integer + decimals + chain-aware) | — |
| Event model | `onNewTask`/`onEvaluate` via Socket.IO | `Raxol.ACP.Event` type union + helpers | SSE transport, `Raxol.ACP.Agent` event dispatch |
| Job session | `Raxol.ACP.Job.Server` (state machine) | — | `Raxol.ACP.JobSession` GenServer with `set_budget`/`fund`/`submit`/`complete`/`reject` |
| Provider adapter | `Raxol.ACP.ContractClient.Onchain` (direct JSON-RPC) | — | `Raxol.ACP.ProviderAdapter.SCA` (Elixir-native, reuses `Raxol.ACP.Wallet.SCA`) |
| Hook integration | (no first-class hooks) | — | `Raxol.ACP.Hooks.FundTransfer` for Xochi |
| Xochi offering | (none) | `Raxol.ACP.Xochi.Offering` (request/deliverable schemas) | `Raxol.ACP.Xochi.SolverAgent` runtime |
| Wallet/signer | `Raxol.ACP.Wallet.SCA` (MAv2 + session keys; `SelfCallRecursionDepthExceeded` fix in #266) | — | v2 SCA provisioning (deploy + install in two userOps, not one) |
| Marketplace registration | — | — | `mix acp.register_offering` task |

## Strategy

We're replacing v1 in place inside this single package, NOT spinning up `raxol_acp_v2`. The v1 modules stay reachable under their original names (`Raxol.ACP.Job.Server`, etc.) while v2 modules go live under the new names (`Raxol.ACP.AssetToken`, `Raxol.ACP.JobSession`, `Raxol.ACP.Agent`). As each v2 module reaches parity with its v1 counterpart, we remove the v1 module in a follow-up PR.

The mix version reflects the in-progress state: `0.2.0-pre.0` while scaffolding, `0.2.0-rc.N` when the v2 surface is feature-complete, `0.2.0` when v1 is removed.

## Why not Privy?

`acp-node-v2` standardizes on `PrivyAlchemyEvmProviderAdapter` for non-custodial key storage (P256 keys in OS keychain). Adopting Privy in Elixir would require either (a) calling a Privy HTTP wrapper from BEAM, or (b) reimplementing Privy's signing protocol natively. Neither is justified for our use case: we already run a BEAM-native MAv2 SCA wallet with Alchemy paymaster + session keys, and the Xochi solver agent is server-side (not a user-facing app where OS keychain matters). The Elixir-native `ProviderAdapter.SCA` keeps everything in process and avoids a third-party runtime dep.

## References

- [acp-node-v2 README](https://github.com/Virtual-Protocol/acp-node-v2/blob/main/README.md)
- [acp-node-v2 migration guide](https://github.com/Virtual-Protocol/acp-node-v2/blob/main/migration.md)
- [Virtuals whitepaper, ACP v2 section](https://whitepaper.virtuals.io/llms-full.txt)
- [ERC-8183 Agentic Commerce](https://ethereum-magicians.org/t/erc-8183-agentic-commerce/27902)
