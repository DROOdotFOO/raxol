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

## Status — 2026-07-07

| Area | v1 (existing) | v2 status |
|------|---------------|-----------|
| Chain config | `Raxol.ACP.Chain` (`acp_contract_address`, `acp_router_address`) | **Done** — adds `acp_core_address` + hook/router/subscription addresses + `acp_server_url` |
| Token amounts | `Fare`/`FareAmount` (Decimal-based) | **Done** — `Raxol.ACP.AssetToken` (raw integer + decimals + chain-aware) |
| Event model | `onNewTask`/`onEvaluate` via Socket.IO | **Done** — `Raxol.ACP.Event`, SSE transport (`transport/sse/parser.ex`), `Raxol.ACP.Agent` event dispatch |
| Job session | `Raxol.ACP.Job.Server` (memo/phase model) -- STILL LIVE | **Partial** — `Raxol.ACP.JobSession` (event/hook model, a DIFFERENT API) exists but is NOT wired into the seller `Queue`/`Runtime`/`bench`, which still drive `Job.Server`. Migration pending (see the entanglement note below). |
| Provider adapter | `Raxol.ACP.ContractClient.Onchain` (direct JSON-RPC) | **Done** — `Raxol.ACP.ProviderAdapter.SCA` (Elixir-native, reuses `Raxol.ACP.Wallet.SCA`) |
| Hook integration | (no first-class hooks) | **Done** — `Raxol.ACP.Hooks.FundTransfer` (note: the storefront relay offering runs plain jobs, `hook = address(0)`) |
| Xochi offering | (none) | **Done** — `Raxol.ACP.Xochi.Offering` + `Raxol.ACP.Xochi.SolverAgent` runtime (8bps storefront fee) |
| Wallet/signer | `Raxol.ACP.Wallet.SCA` (MAv2 + session keys) | **Done** — two-userOp v2 provisioning (`Wallet.SCA.Provisioner`: deploy + install as separate userOps) |
| Marketplace registration | — | **Done** — `mix acp.register_offering` |

**Landed (2026-07-07 wave):** `ProviderAdapter.SCA` + two-userOp `Provisioner`.

## Why the "v1 hard-cut" is blocked (entanglement, found 2026-07-07)

The `0.2.0` step ("remove v1") is NOT a simple deletion. Two blockers:

1. **`Job.Server` is not dead v1 code -- it is the live seller-stack lifecycle.**
   The shipped seller `Queue`/`Runtime` and `mix raxol_acp.bench` drive
   `Job.Server.accept_request`/`accept_payment`/`approve`/`transition`/`deliver`.
   `JobSession` is the v2 replacement but has a completely different API
   (`set_budget`/`fund`/`submit`/`complete`/`reject`, event/hook model), so it is
   NOT a drop-in. Deleting `Job.Server` first requires **migrating the seller
   Queue/Runtime/bench onto `JobSession`** -- a real rewrite of the event routing,
   its own project. Until then `Job.Server` stays.

2. **The `ContractClient.Onchain` `:v1 -> :v2` flip is nearly cosmetic.** Its `:v2`
   branch targets `acp_router_address` (legacy ACPRouter), NOT the active
   `AgenticCommerceV3` core. The active v2 core is reached through
   `Raxol.ACP.HookClient` (which the storefront uses) and does not consult
   `acp_version`. So flipping the default swaps one legacy contract for another;
   the real question is whether `ContractClient.Onchain` should be retired or
   repointed at `AgenticCommerceV3` -- a separate decision, not part of a deletion.

Prerequisite before either: staging-validate the active v2 (`AgenticCommerceV3`)
lifecycle end-to-end (needs funds / a Base staging run).

## Selecting the contract version

`Raxol.ACP.ContractClient.Onchain` reads `Application.get_env(:raxol_acp, :acp_version, :v1)`; the code default is `:v1` (the sunsetted ACPSimple). `ACP_VERSION=v2` at boot (wired in `config/runtime.exs`, applies in every env) switches this client to `acp_router_address` (the legacy ACPRouter) -- NOT the active `AgenticCommerceV3` core. The active core is reached through `Raxol.ACP.HookClient`, which ignores `acp_version` entirely; the storefront offering already runs there. So `ACP_VERSION` only selects between the two legacy `ContractClient.Onchain` targets, and is useful mainly for exercising the ACPRouter path in a non-storefront context.

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
