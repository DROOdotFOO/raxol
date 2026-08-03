# RUNBOOK: `custom_console_agent` on Base Sepolia

How to take the `custom_console_agent` offering from a clean checkout to a live,
funded, registered seller on Base Sepolia (chain `84532`), then promote to Base
mainnet (`8453`). The console offering sells a validated Hermes/OpenClaw agent
package as a **plain job** (`requiredFunds: false`) -- no escrowed principal, no
corridor liquidity.

Everything that moves funds or talks to Virtuals is an OPERATOR step (needs a
funded wallet + network egress). The steps up to that -- code, config, offline
rehearsal -- are reproducible offline.

## 0. Prerequisites

- Elixir/OTP toolchain; `mix deps.get` in `packages/raxol_earn`.
- A wallet the agent signs with. Default: a bring-your-own Alchemy Modular
  Account v2 SCA (`ProviderAdapter.SCA`); fallback: the Privy signer sidecar
  (`ProviderAdapter.Privy`) if sandbox registration insists on a Virtuals-issued
  wallet. Keys come from `Raxol.Payments.Wallets.{Env, Op}` -- never a literal.
- The `@virtuals-protocol/acp-cli` for one-time identity provisioning only (it is
  NOT in the runtime path).
- For `bench_validated` delivery: an operator wrapper per runtime that boots the
  open-source runtime against a package dir (see `console_bench` in
  `config/console_offering.example.exs`).

## 1. One-time identity + funding (operator, via the acp CLI / dashboard)

1. `acp configure` (OAuth), then `acp agent create` (wallet + email) and
   `acp agent add-signer` (browser-approved). Optionally `acp email provision`.
2. Fund the wallet on Sepolia: native gas via a Base Sepolia faucet, plus the
   sandbox test USDC (`acp wallet topup --chain-id 84532`, or the sandbox faucet).
3. Register the agent on the Virtuals dashboard. None of this touches the runtime;
   `Raxol.Earn.Auth` mints the API JWT at boot from an EIP-712 signature over the
   same adapter, so there is no separate API credential to manage.

## 2. Configure the seller (copy from the example)

Copy the keys you need from `config/console_offering.example.exs` into your
`config/runtime.exs`. The Sepolia-specific values:

| Setting            | Sepolia dry-run                                   | Mainnet promote            |
| ------------------ | ------------------------------------------------- | -------------------------- |
| `seller_chain_id`  | `84_532` (Queue defaults to 8453 -- MUST set)     | `8453`                     |
| ACP server / relay | `api-dev.acp.virtuals.io` / `acpx.virtuals.gg`    | `api.acp.virtuals.io`      |
| USDC               | Virtuals sandbox test USDC via `chain_overrides`  | canonical Circle USDC      |
| adapter            | `ProviderAdapter.SCA` (or `.Privy`)               | same, mainnet bundler keys |
| checkpoint         | `{:ets, :raxol_earn_checkpoint}`                   | durable `{module, handle}` |
| `require_checkpoint` | `true`                                          | `true`                     |

`chain_overrides` is keyed by network name (`:sepolia`), not chain id. Sepolia
defaults to Circle USDC (`0x036CbD53842c5426634e7929541eC2318f3dCF7e`); override
`usdc_address` with the Virtuals sandbox test token for funding checks.

Set `seller_job_api_opts` (auth + `server_url` + `chain_ids: [84_532]`) so the
boot/reconnect `Resync` has an API to read `get_active_jobs` from and so
delivered bodies are posted out-of-band.

## 3. Register the offering on Virtuals

```
mix earn.register_offering --offering console --pretty --out console_offering.json
```

Emits the marketplace document (name `custom_console_agent`, `priceType: fixed`,
`price: 10`, `requiredFunds: false`, `slaMinutes: 60`, and the `requirement` JSON
Schema). Upload it in the dashboard ("Add Job"). Network/contract addresses are
deliberately NOT in this document -- they live in the agent runtime.

## 4. Offline rehearsal (no funds, no network)

Prove the seller stack end-to-end against the in-memory backend + mock adapter
before going live:

```
MIX_ENV=test mix test test/raxol/acp/console/ \
  test/raxol/acp/job_session/provider_checkpoint_test.exs \
  test/raxol/acp/seller/resync_recovery_test.exs
mix raxol_earn.bench      # drives synthetic jobs through the seller stack
```

The provider-checkpoint and resync-recovery suites are the M1 acceptance gate:
they inject a crash between handler-return / sign / mirror and assert exactly one
on-chain submit through to completion.

## 5. Live dry-run on Sepolia (operator)

With the seller configured and running (`seller_enabled: true`), a scripted mock
buyer -- a second wallet driving `HookClient.create_job` / `fund` / `complete` --
exercises the registered offering. Confirm the deliverable hash lands on-chain via
`submit` and the body is posted out-of-band; then approve to complete.

Two assumptions only the live run can pin (the `Resync` normalizer is deliberately
tolerant and skips anything unrecognized):

1. The `get_active_jobs` field names / phase encoding match what `Seller.Resync`
   normalizes (v2 names, acp-node aliases, numeric enum).
2. The job-id form is consistent between the REST API and the Socket.IO relayer,
   so session keys match across the two planes.

Kill the BEAM mid-flight (between funded -> submit -> complete) and restart: with
`checkpoint` + `Resync` wired, it must resume without a second submit or charge.

## 6. Buy side (autonomous buyer)

The buyer is the mirror of the seller: it discovers an offering, funds a job
within spend limits, evaluates the deliverable, and survives crashes without
double-spending. It is opt-in via `buyer_enabled: true`. Copy the keys you need
from `config/buyer.example.exs`.

### 6a. Configure

Set at minimum `buyer_provider_adapter` (the signing adapter), `buyer_address`,
`buyer_chain_id: 84_532`, a `buyer_ledger` + `buyer_spending_policy` (the spend
gate fails closed in production with no policy), and `buyer_job_api_opts` (for
discovery + resync). Set `checkpoint` + `require_checkpoint: true` for crash
safety. The `Buyer.Runtime` subscribes to `buyer_backend` for this buyer's job
lifecycle events; the backend process is started by the host app (for the
offline rehearsal, the shared `Seller.Backend.InMemory`).

### 6b. Offline rehearsal (no funds, no network)

Drive a purchase through the driver against mocks:

    intent = %{
      offering: "custom_console_agent",
      provider: seller_wallet,
      amount: Raxol.Earn.AssetToken.usdc(10, 84_532)
    }
    {:ok, job_id} = Raxol.Earn.Buyer.Planner.buy(intent)

with `buyer_provider_adapter` = `ProviderAdapter.Mock` and
`buyer_job_id_resolver` = `JobIdResolver.Mock`. The buyer reserves, writes
`createJob`, resolves the job_id, and tracks the job; dispatching a `:budget_set`
then a `:submitted` event drives `fund` -> evaluate -> `complete`. This is what
`test/raxol/acp/buyer/queue_test.exs` exercises.

### 6c. Live dry-run on Sepolia (operator)

With `buyer_enabled: true` and a funded second wallet, `Buyer.Planner.buy/1`
originates a real job against the registered offering. **Confirm during the run**
(the reason `buyer_job_id_resolver` is a seam):

1. The `JobCreated` event signature / indexed `jobId` position the
   `JobIdResolver.Receipt` decodes -- override `event_signature`/`topic_index`
   in config if they differ from the placeholder.
2. That `createJob`'s `description` round-trips on-chain and is readable via
   `get_active_jobs` -- the crash reconcile-by-tag path depends on it.
3. The job-id form matches across the receipt, the REST API, and session keys.

Kill the BEAM mid-flight (between reserve -> create -> fund) and restart: with
`checkpoint` wired, `buy/1` resumes from the recorded phase -- exactly one
`createJob` (reconciled by the request tag) and one `fund`, budget reserved once.

## 7. Promote to mainnet

Flip the table in section 2 to the mainnet column: `seller_chain_id: 8453`
(and `buyer_chain_id: 8453`), `api.acp.virtuals.io`, canonical USDC (drop the
`chain_overrides` block), and a durable checkpoint store. Re-run section 3 with
the mainnet dashboard.

## Notes

- Wallet-funded compute: point `console_inference` at Virtuals compute
  (`https://compute.virtuals.io/v1`, key `VIRTUALS_API_KEY`) so generation runs on
  the agent wallet, not a separate API bill.
- Semantics of the M1 guarantee: **exactly-once-effective, at-least-once-attempted.**
  One deliverable hash can ever exist per job; a sign-then-crash replay can resubmit
  that same hash, which reverts on the contract's phase guard (costs gas, corrupts
  nothing).
