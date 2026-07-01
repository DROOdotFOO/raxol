# Agentic Commerce

Agents that can pay for things. `raxol_payments` gives any Raxol agent autonomous payment capabilities (wallet identity, quotes, transfers, spending limits) across chains and protocols.

## How It Works

An agent returns payment commands from `update/2` the same way it returns shell or async commands. The `SpendingHook` intercepts commands before execution, checks them against the `SpendingPolicy`, and the `Ledger` tracks what's been spent.

```
Agent update/2 returns command
    |
    v
SpendingHook checks SpendingPolicy (per-request / session / lifetime limits)
    |
    v
Router.select/1 picks protocol based on context:
    same-chain HTTP 402 --> x402 or MPP (auto-pay)
    cross-chain         --> Xochi (intent-based settlement)
    privacy             --> Xochi (stealth/shielded)
    |
    v
Wallet signs the transaction (EIP-712)
    |
    v
Ledger records the spend
```

## Wallet Backends

Two wallet implementations behind the `Raxol.Payments.Wallet` behaviour:

- `Wallets.Env`: private key from an environment variable. Simple, good for dev and CI.
- `Wallets.Op`: private key fetched from 1Password via a GenServer. No plaintext key on disk.

Both implement the `Raxol.Payments.Wallet` callbacks: `address/0`, `chain_id/0`, and three signing functions: `sign_message/1` (raw message), `sign_typed_data/3` (EIP-712 typed data), and `sign_hash/1` (precomputed 32-byte digest). The behaviour has no balance callback.

## Protocols

### x402 (Coinbase)

Handles HTTP 402 Payment Required responses. The server says "pay me X to address Y," the wallet signs an EIP-712 authorization (ERC-3009 `transferWithAuthorization`), and the signed payload goes back in the retry header. All transparent to the agent.

### MPP (Machine Payments Protocol)

Stripe/Tempo's protocol for machine-to-machine payments. Same HTTP 402 flow, different wire format. The `AutoPay` Req plugin handles both x402 and MPP automatically; just add it as a response step.

### Xochi

Intent-based cross-chain settlement. The agent says "I want to pay 10 USDC on Base to address X on Arbitrum," Xochi quotes a fee, the wallet signs the intent, and Riddler's solver network handles the actual cross-chain execution.

The fee has three additive layers rather than a single tier percentage: a solver spread plus gas floor (Riddler, never discounted), a venue fee (Xochi), and a routing fee (Raxol, which funds the token buyback, so agent volume routed through raxol feeds the flywheel). Trust discounts carve down the venue and routing layers only, leaving the solver floor identical at every tier. Headline totals run 0.10-0.40% by tier and asset (stablecoins lower, volatile assets higher), from Standard at 0.22% stable / 0.40% volatile down to Institutional at 0.10% / 0.22%.

The quote will carry an optional `fee_breakdown`: the per-layer split (solver, venue, routing), price impact, gas floor, total, and `surplus_share_pct` (the solver keeps 15% of positive-slippage surplus, the user keeps 85%). The routing line is raxol's own cut, worth surfacing to agents. It stays absent until Riddler emits it and the worker forwards it, and the `QuoteResponse` schema does not parse it yet, so treat it as a forthcoming field rather than something to read today.

Flow: `get_quote/2` -> `execute/3` (wallet signs EIP-712 intent) -> `poll_status/3`.

Xochi is the default for cross-chain and privacy (stealth addresses, shielded transfers). It's cash-positive by design: the protocol takes a fee, the agent pays it, done.

### Riddler (direct solver, B2B only)

Direct access to Riddler's Commerce API for bulk/institutional flows. Cash-negative for the protocol (solver subsidizes execution), so don't use it for agent payments. It exists for B2B integrations where the business relationship justifies the economics. The `Protocols.Riddler` module itself is deprecated and now delegates to Xochi internally; prefer `Protocols.Xochi` directly.

## Spending Controls

Three layers of limits in `SpendingPolicy`:

- **Per-request**: max amount for a single transaction
- **Per-session**: rolling total within one agent session
- **Lifetime**: hard cap across all sessions

The `Ledger` is an ETS-backed GenServer that tracks cumulative spend. `SpendingHook` implements the `CommandHook` behaviour from raxol_agent. It runs before every command and can deny execution if limits would be exceeded.

Both spend paths reserve atomically before signing: the `SpendGate` choke point (payment Actions) and `SpendingHook` (Pay directives) call `Ledger.try_spend`, which checks the caps and records in one step, and refund via `Ledger.release` when execution then fails, so two commands cannot both pass a check before either records. A non-positive or non-finite amount is rejected up front (it can never lower the running total). A missing policy leaves the gate permissive by default; a fund-moving deployment sets `require_policy: true` (payment context or `config :raxol_payments, :require_policy`) so `SpendGate` fails closed instead of allowing unlimited spend.

## Crash Recovery

Cross-chain settlement is asynchronous: there is a window between dispatching an intent (sign + submit) and confirming it landed. A crash in that window, on a runtime with no fault isolation, makes the restarted agent re-quote and sign a second time, paying twice.

`Raxol.Payments.Checkpoint` closes the window. The cross-chain Actions (`ExecuteXochiIntent`, `ExecuteRelayTransfer`) checkpoint the dispatched intent before submitting it, keyed by a stable idempotency key derived from the payment. On a re-run after a crash, the Action finds the checkpoint and returns the in-flight intent for the caller to poll, instead of reserving budget and signing again. The spend is reserved and the signature released exactly once across the crash.

The store is injected via `context[:checkpoint]` as a `{module, handle}` pair, so the recovery layer does not bind raxol_payments to a particular durability mechanism:

- `Checkpoint.ETS`: an ETS table; survives a process crash when owned by a process that outlives it (a supervisor, the cockpit). Used for standalone runs and the demo.
- `Checkpoint.ContextStore`: backed by `Raxol.Agent.ContextStore`, so a deployed agent's in-flight intent persists in the same durable store that backs its own crash recovery.
- nil (the default): recovery disabled; every call quotes and signs.

Without a checkpoint, `ExecuteXochiIntent` still proceeds but emits `[:raxol, :payments, :xochi, :unchecked_settlement]`, so the double-settle exposure is observable rather than silent. A fund-moving deployment closes the window by injecting a durable store and setting `require_checkpoint: true` (payment context or `config :raxol_payments, :require_checkpoint`), which fails the Action closed with `{:error, %Failure{reason: :checkpoint_required}}` before any signature when no store is present. A poll that never reaches a terminal status returns `%Failure{reason: :stranded}` and emits `[:raxol, :payments, :xochi, :intent_stranded]` with the intent id, so a stranded settlement is reconciled rather than blindly re-executed.

The relay rail keys on the logical payment rather than its client-minted `transfer_id`, so a resume reuses the same `transfer_id` and an idempotent broadcaster dedupes a retried deposit. A definite execution failure (nothing dispatched) drops the checkpoint so a later retry starts clean. Set `context[:idempotency_key]` to force two otherwise-identical payments apart.

## Agent Actions

Twelve actions registered via the `Raxol.Agent.Action` behaviour, callable by LLMs:

| Action | What it does |
|--------|-------------|
| `payment_get_wallet_info` | Return the agent's wallet address and chain ID |
| `payment_get_quote` | Get a price quote for a transfer (route, fees; layered `fee_breakdown` forthcoming) |
| `payment_transfer` | Execute a payment |
| `payment_spending_status` | Current spend vs limits |
| `payment_list_history` | Transaction history for this session |
| `payment_create_mandate` | Issue a Xochi delegation envelope from this wallet |
| `payment_list_mandates` | List locally-stored Mandates (as member or as agent) |
| `payment_revoke_mandate` | Locally delete a stored Mandate (Xochi KV unaffected) |
| `payment_execute_xochi_intent` | Dispatch a cross-chain Xochi intent (checkpointed) |
| `payment_poll_xochi_status` | Poll the status of a dispatched Xochi intent |
| `payment_execute_relay_transfer` | Initiate a Tron transfer via Riddler Relay (checkpointed); Tron is public-only |
| `payment_poll_relay_status` | Poll a dispatched relay (Tron) transfer to a terminal status |

## Mandate (Xochi Delegation Envelope)

`Raxol.Payments.Mandate` is a per-request EIP-712 envelope that lets an AI agent transact on Xochi under a human Member's identity, inheriting that Member's Trust Tier and Privacy Level. The Member signs an envelope binding a specific agent wallet to a scoped budget; the agent presents `X-Xochi-Delegation: base64url(envelope)` on every protected Xochi call. Xochi verifies the signature server-side and decrements the budget in KV per call. No persistent session.

The schema mirrors `xochi/packages/shared/src/eip712.ts:182-263` exactly (snake_case fields, `string[]` scopes, chainId pinned to 1, zero verifyingContract for off-chain). The Elixir digest is verified byte-for-byte against viem's `hashTypedData`.

```elixir
alias Raxol.Payments.Mandate

{:ok, m} = Mandate.build(%{
  human_wallet: member_wallet.address(),
  agent_wallet: "0x...",
  scopes: ["quote", "execute"],
  max_amount_usd: 1000,
  max_calls: 50,
  expires_at: System.system_time(:second) + 3600
})
{:ok, signed} = Mandate.sign(m, member_wallet)
:ok = Mandate.Store.put(signed)
```

On the agent's outbound HTTP path:

```elixir
Req.new(url: "https://api.xochi.fi/api/intent/quote")
|> Raxol.Payments.Req.Mandate.attach(agent_wallet: agent_addr)
|> Req.post(json: quote_body)
```

`Mandate.Store` is a singleton (named ETS tables); start exactly one per node. Optional DETS persistence via `:mandate_store_path` in `config :raxol_payments`. Mandate is **orthogonal** to `SpendingPolicy`/`Ledger`: those govern operator-set session budgets locally; Mandate is a credential carried to Xochi for tier inheritance.

v1 follows the locked design at `xochi/docs/planning/agent-auth.md`. Server-side revoke endpoint, on-chain registry, Verified-Agent metadata, issuer browser UI, and auto-rotation on exhaustion are deferred.

## AutoPay (Req Plugin)

`Raxol.Payments.Req.AutoPay` is a Req response step. Add it to any Req client and HTTP 402 responses get handled transparently:

```elixir
client = Req.new(base_url: "https://api.example.com")
  |> Raxol.Payments.Req.AutoPay.attach(wallet: my_wallet)

# If the server returns 402, AutoPay signs and retries automatically
{:ok, response} = Req.get(client, url: "/expensive-endpoint")
```

## Package Details

Standalone package at `packages/raxol_payments/`. Depends on `raxol_agent` at compile time only (`runtime: false`) for the Action macro and CommandHook behaviour. Runtime deps: `req`, `ex_secp256k1`, `ex_keccak`, `jason`, `decimal`.

## See Also

- [Agent Framework](AGENT_FRAMEWORK.md): how agents work (TEA, sessions, teams, commands)
- [Distributed Swarm](DISTRIBUTED_SWARM.md): multi-node agent coordination
