# Agentic Commerce

Agents that can pay for things. `raxol_payments` gives any Raxol agent autonomous payment capabilities (wallet identity, quotes, transfers, spending limits) across chains and protocols.

## How it works

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

- `Wallets.Env`: private key from an environment variable. Simple, good for dev and CI. In a deployed release it refuses to load (a plaintext key in an env var lands in process listings and crash dumps) unless the operator opts in with `RAXOL_ALLOW_ENV_WALLET=true` or `config :raxol_payments, :allow_env_wallet, true`. Use `Wallets.Op` in production.
- `Wallets.Op`: private key fetched from 1Password via a GenServer. No plaintext key on disk. The key is fetched once at first use, wrapped in a `Secret`, and signed with locally, so signing does not round-trip 1Password per request.

Both implement the `Raxol.Payments.Wallet` callbacks: `address/0`, `chain_id/0`, and three signing functions: `sign_message/1` (raw message), `sign_typed_data/3` (EIP-712 typed data), and `sign_hash/1` (precomputed 32-byte digest). The behaviour has no balance callback.

## Protocols

### x402 (Coinbase)

Handles HTTP 402 Payment Required responses. The server says "pay me X to address Y," the wallet signs an EIP-712 authorization (ERC-3009 `transferWithAuthorization`), and the signed payload goes back in the retry header. All transparent to the agent.

### MPP (Machine Payments Protocol)

Stripe/Tempo's protocol for machine-to-machine payments. Same HTTP 402 flow, different wire format. The `AutoPay` Req plugin handles both x402 and MPP automatically; just add it as a response step.

### Permit2

`PermitWitnessTransferFrom` signing for Riddler's `/order` origin pull. Where x402 signs an ERC-3009 `transferWithAuthorization` (USDC only), Permit2 covers most ERC-20 tokens: the wallet signs a Permit2 witness that binds the transfer to the solver's order, so Riddler can pull the origin funds gaslessly (the agent must already hold a one-time Permit2 approval on-chain). `Protocols.Permit2.sign_quote/3` returns the digest, signed object, and signature; the digest is pinned byte-for-byte against viem in CI.

### Xochi

Intent-based cross-chain settlement. The agent says "I want to pay 10 USDC on Base to address X on Arbitrum," Xochi quotes a fee, the wallet signs the intent, and Riddler's solver network handles the actual cross-chain execution.

The fee has three additive layers rather than a single tier percentage: a solver spread plus gas floor (Riddler, never discounted), a venue fee (Xochi), and a routing fee (Raxol, which funds the token buyback, so agent volume routed through raxol feeds the flywheel). Trust discounts carve down the venue and routing layers only, leaving the solver floor identical at every tier. Headline totals run 0.10-0.40% by tier and asset (stablecoins lower, volatile assets higher), from Standard at 0.22% stable / 0.40% volatile down to Institutional at 0.10% / 0.22%.

The quote will carry an optional `fee_breakdown`: the per-layer split (solver, venue, routing), price impact, gas floor, total, and `surplus_share_pct` (the solver keeps 15% of positive-slippage surplus, the user keeps 85%). The routing line is raxol's own cut, worth surfacing to agents. It stays absent until Riddler emits it and the worker forwards it, and the `QuoteResponse` schema does not parse it yet, so treat it as a forthcoming field rather than something to read today.

Flow: `get_quote/2` -> `execute/3` (wallet signs EIP-712 intent) -> `poll_status/3`.

For a storefront that settles on a buyer's behalf, the signing and the submission split into a buyer-side half and a relay-side half:

- `sign_intent/2,3` and `quote_and_sign/3` (buyer side) quote and sign the intent and return the opaque bundle `{intent_id, quote_id, signature, nonce, pull_signature}` **without submitting**: the buyer hands this to the storefront.
- `execute_signed/2` (relay side) posts a pre-signed bundle to Xochi **without re-signing**, so the relay never holds the buyer's key.
- `execute/4` is the two composed: `sign_intent` then `execute_signed`.

The Xochi Cross-Chain Transfer ACP offering (in `raxol_earn`, see [ACP](ACP.md)) is built on this split: the buyer signs, raxol relays. `packages/raxol_earn/examples/buyer_signed_intent.exs` shows the buyer flow.

Xochi is the default for cross-chain and privacy (stealth addresses, shielded transfers). It's cash-positive by design: the protocol takes a fee, the agent pays it, done.

### Riddler (direct solver, B2B only)

Direct access to Riddler's Commerce API for bulk/institutional flows. Cash-negative for the protocol (solver subsidizes execution), so don't use it for agent payments. It exists for B2B integrations where the business relationship justifies the economics. The `Protocols.Riddler` module itself is deprecated and now delegates to Xochi internally; prefer `Protocols.Xochi` directly.

## Trust and Compliance (ZKSAR)

ZKSAR (Zero-Knowledge Sanctions/AML Reporting) lets an agent prove compliance facts without
revealing the underlying data, and turns those proofs into a trust score that unlocks lower
fees and stronger privacy. The zero-knowledge proofs themselves are verified on-chain or in
the Xochi oracle; `Raxol.Payments.Zksar` verifies the oracle's signed attestation result
(type, expiry, issuer, structural integrity, and that the signature recovers to a trusted
issuer).

Six proof types (`@proof_types`):

| Type | Proves |
|------|--------|
| `:compliance` | Score below a jurisdiction threshold |
| `:risk_score` | A score comparison without revealing the score |
| `:pattern` | No structuring or velocity anomalies |
| `:attestation` | A valid credential exists |
| `:membership` | Address is in a whitelist |
| `:non_membership` | Address is NOT on a sanctions list |

`Zksar.TrustScore.aggregate/2` folds verified proofs into a 0-100 score with diminishing
returns: proofs are weighted by type, sorted descending, and each successive proof
contributes less (the first at full weight, the second about 91%, the third about 73%).

`Raxol.Payments.PrivacyTier` maps the score to a tier (the Xochi whitepaper's Glass Cube
model), which sets the fee and the settlement mode:

| Score | Tier | Fee (bps) | Settlement |
|-------|------|:---:|-----------|
| 0-24 | `:standard` | 30 | public |
| 25-49 | `:stealth` | 25 | stealth |
| 50-74 | `:private` | 20 | shielded |
| 75+ | `:sovereign` | 15 | shielded |

`:private` requires a `:compliance` attestation and `:sovereign` requires `:compliance` plus
`:non_membership`; without them, the tier is walked down toward `:standard`. Two lower-privacy
tiers (`:open`, `:public`) exist only as an opt-in override, so a user can choose to reveal
more, never less by default.

`Raxol.Payments.Router` is the verification choke point. Callers pass raw, signed
attestations; the Router runs `Zksar.verify_batch/2` against an operator-pinned issuer
allowlist (`config :raxol_payments, :zksar_allowed_issuers`) on every path, replacing the
attestation set with only the verified subset before it scores or checks tier requirements. It
fails closed: with the allowlist unset (the default `[]`), no attestation can be verified, so
none buys trust. A self-asserted `%{valid: true}` map is not a proof.

Signature verification is implemented and on by default, but the digest scheme it checks
(EIP-191 over canonical attestation fields) is provisional: it has not yet been reconciled
byte-for-byte with the live Xochi oracle signer, so it fails closed on mismatch (rejecting
real attestations rather than accepting forged ones) until a production vector is pinned.

## Spending Controls

Three layers of limits in `SpendingPolicy`:

- **Per-request**: max amount for a single transaction
- **Per-session**: rolling total within one agent session
- **Lifetime**: hard cap across all sessions

The `Ledger` is an ETS-backed GenServer that tracks cumulative spend. `SpendingHook` implements the `CommandHook` behaviour from raxol_agent. It runs before every command and can deny execution if limits would be exceeded.

Both spend paths reserve atomically before signing: the `SpendGate` choke point (payment Actions) and `SpendingHook` (Pay directives) call `Ledger.try_spend`, which checks the caps and records in one step, and refund via `Ledger.release` when execution then fails, so two commands cannot both pass a check before either records. A non-positive or non-finite amount is rejected up front (it can never lower the running total). A missing policy leaves the gate permissive in development, but a deployed release fails closed: `require_policy` defaults to true in production (a deployed OTP release, detected by `Raxol.Payments.Deployment` via `RELEASE_NAME`) and false in development and tests, so a production `SpendGate` with no `SpendingPolicy` rejects the spend rather than allowing unlimited spend. Set the context flag or `config :raxol_payments, :require_policy` to override.

## Crash Recovery

Cross-chain settlement is asynchronous: there is a window between dispatching an intent (sign + submit) and confirming it landed. A crash in that window, on a runtime with no fault isolation, makes the restarted agent re-quote and sign a second time, paying twice.

`Raxol.Payments.Checkpoint` closes the window. The cross-chain Actions (`ExecuteXochiIntent`, `ExecuteRelayTransfer`) checkpoint the dispatched intent before submitting it, keyed by a stable idempotency key derived from the payment. On a re-run after a crash, the Action finds the checkpoint and returns the in-flight intent for the caller to poll, instead of reserving budget and signing again. The spend is reserved and the signature released exactly once across the crash.

The store is injected via `context[:checkpoint]` as a `{module, handle}` pair, so the recovery layer does not bind raxol_payments to a particular durability mechanism:

- `Checkpoint.ETS`: an ETS table; survives a process crash when owned by a process that outlives it (a supervisor, the cockpit). Used for standalone runs and the demo.
- `Checkpoint.ContextStore`: backed by `Raxol.Agent.ContextStore`, so a deployed agent's in-flight intent persists in the same durable store that backs its own crash recovery.
- nil (the default): recovery disabled; every call quotes and signs.

Without a checkpoint, `ExecuteXochiIntent` in development still proceeds but emits `[:raxol, :payments, :xochi, :unchecked_settlement]`, so the double-settle exposure is observable rather than silent. A deployed release fails closed by default: `require_checkpoint` defaults to true in production (detected via `RELEASE_NAME`) and false in development and tests, so a production Action with no durable store returns `{:error, %Failure{reason: :checkpoint_required}}` before any signature. Inject a store to close the window; set the context flag or `config :raxol_payments, :require_checkpoint` to override. A poll that never reaches a terminal status returns `%Failure{reason: :stranded}` and emits `[:raxol, :payments, :xochi, :intent_stranded]` with the intent id, so a stranded settlement is reconciled rather than blindly re-executed.

The relay rail keys on the logical payment rather than its client-minted `transfer_id`, so a resume reuses the same `transfer_id` and an idempotent broadcaster dedupes a retried deposit. A definite execution failure (nothing dispatched) drops the checkpoint so a later retry starts clean. Set `context[:idempotency_key]` to force two otherwise-identical payments apart.

## Production Safety

A process that holds a signing key is the crown jewel, so the fund-moving defaults are paranoid in a deployed release and permissive in development and tests. `Raxol.Payments.Deployment.production?/0` decides which: it is true for a deployed OTP release (detected by the `RELEASE_NAME` the release boot script sets, which survives into the running node where `Mix.env/0` does not), and can be forced either way with `config :raxol_payments, :deployment` or `RAXOL_PAYMENTS_DEPLOYMENT`.

- **Signing boundary.** Every fund-moving Action reaches `wallet.sign_*` only after `SpendGate.authorize/3` returns `:ok`. `sign_hash/1` (the opaque-digest signer) is reachable only through `Mandate.sign/2`, which builds the digest from a validated struct, never an arbitrary hash. A property test asserts a gate rejection yields zero signatures across the amount space, and a guard test keeps any new Action from reaching a signer without the gate.
- **Fail-closed defaults.** In production, `require_policy` and `require_checkpoint` default to true (see Spending Controls and Crash Recovery), and `Wallets.Env` refuses to load (see Wallet Backends).
- **EIP-712 golden vectors.** The digest for every signed struct (x402 ERC-3009, the Xochi intent, the Permit2 witness, the Mandate) is pinned to a committed value that default CI checks on every run, so a change to a type definition or the encoder turns CI red rather than silently signing against the wrong struct.

Two boot gates fail closed for a fund-moving deployment; call them at startup, alongside `Protocols.Xochi.assert_origin_pull_pinned!/2`:

```elixir
# In your application start/2, before serving traffic:
Raxol.Payments.Deployment.assert_distribution_secure!()
# Halts a production node that participates in plain (non-TLS) Erlang
# distribution: a shared magic cookie lets any peer invoke exported functions
# and read ETS. Require -proto_dist inet_tls with per-node certs, or set
# RAXOL_ALLOW_INSECURE_DISTRIBUTION=true to override.

Raxol.Payments.Deployment.assert_signing_isolated!()
# Halts a production node that both signs and exposes the interactive REPL
# (RAXOL_REPL_EXPOSED=true). Evaluating code on a node that holds keys is a
# capability-escape surface: keep the REPL on a node that cannot sign.
```

## Agent Actions

Thirteen actions registered via the `Raxol.Agent.Action` behaviour, callable by LLMs:

| Action | What it does |
|--------|-------------|
| `payment_get_wallet_info` | Return the agent's wallet address and chain ID |
| `payment_get_quote` | Get a price quote for a transfer (route, fees; layered `fee_breakdown` forthcoming) |
| `payment_transfer` | Execute a payment |
| `payment_spending_status` | Current spend vs limits |
| `payment_list_history` | Transaction history for this session |
| `payment_create_mandate` | Issue a Xochi delegation envelope from this wallet |
| `payment_list_mandates` | List locally-stored Mandates (as member or as agent) |
| `payment_revoke_mandate` | Locally delete a stored Mandate (server budget honored until expiry; a 410 auto-prunes) |
| `payment_execute_xochi_intent` | Dispatch a cross-chain Xochi intent (checkpointed) |
| `payment_poll_xochi_status` | Poll the status of a dispatched Xochi intent |
| `payment_execute_deposit_route` | Fetch + verify a Tron-origin deposit-route quote (bare `deposit_address`, attestation-checked); Tron origins have no gasless pull |
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

v1 follows the locked design at `xochi/docs/planning/agent-auth.md`. On the agent side, a `410 Gone` from Xochi (a revoked or exhausted envelope) prunes the local mandate through the outbound plugin and flags the response as terminal, so a server-side revocation converges locally without a manual `payment_revoke_mandate` call. The authenticated server-side revoke endpoint itself, along with the on-chain registry, Verified-Agent metadata, issuer browser UI, and auto-rotation on exhaustion, remain deferred.

### Two delegation models (Mandate vs SCA session key)

A deployed agent may carry two capability-delegation credentials, and they govern two different surfaces. Keep them distinct in an ops runbook so a de-authorization is complete:

- **Xochi Mandate** (`Raxol.Payments.Mandate`, this package) governs Xochi API calls. A Member signs an EIP-712 envelope binding an agent wallet to a scoped budget; the agent presents it per call via `Req.Mandate`. Revoke it by letting it expire, or (once Xochi ships the revoke endpoint) by `H(envelope)`; a `410 Gone` prunes the local copy.
- **ERC-4337 SCA session key** (`Raxol.Earn.Wallet.SCA`, in `raxol_earn`) governs Base/ACP UserOps. A session key installed on the modular account via `installValidation` signs sponsored UserOps for on-chain ACP job actions.

The two are independent: revoking one does not revoke the other. An agent that must be fully de-authorized needs both its Mandate revoked or expired **and** its SCA session key uninstalled. The Mandate is a Xochi-side credential scoped to Xochi endpoints; the session key is a Base-side signer scoped to the modular account. A leaked key revoked on Xochi but still holding a valid session key can still act through the ACP path, and vice versa.

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
