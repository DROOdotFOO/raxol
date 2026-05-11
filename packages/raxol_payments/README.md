# Raxol Payments

Agent payment protocols for Elixir. Autonomous agents that can pay for things -- x402/MPP auto-pay, Xochi cross-chain intents, stealth addresses, ZKSAR attestation, Xochi Mandate delegation, spending controls.

## Install

```elixir
{:raxol_payments, "~> 0.1"}
```

## Features

- **Protocol behaviour** -- pluggable payment protocols (Xochi, x402, MPP)
- **Wallet behaviour** -- `Wallets.Env` (env var) and `Wallets.Op` (1Password via GenServer)
- **AutoPay** -- Req response step handling HTTP 402 transparently
- **Xochi** -- cross-chain intent settlement (quote -> sign -> execute -> poll)
- **Stealth** -- ERC-5564/ERC-6538 stealth addresses (~300 LOC, secp256k1)
- **ZKSAR** -- zero-knowledge attestation verification (6 proof types)
- **TrustScore** -- diminishing-returns trust aggregation (0-100)
- **PrivacyTier** -- Glass Cube model (6 tiers, attestation-gated)
- **Router** -- auto-select protocol based on chain, privacy, trust score
- **SpendingPolicy + Ledger** -- per-request/session/lifetime spending limits
- **PXE Bridge** -- Aztec Private eXecution Environment client (JSON-RPC 2.0)
- **Mandate** -- Xochi delegation envelopes (per-request EIP-712 auth, agent inherits Member's tier). Verified byte-for-byte against viem's `hashTypedData`. See `Raxol.Payments.Mandate`, `Mandate.Store`, `Req.Mandate` plugin, and the `payment_create_mandate` / `payment_list_mandates` / `payment_revoke_mandate` agent actions.

## Quick Start

```elixir
alias Raxol.Payments.{Router, Req.AgentPlugin}

# Router auto-selects protocol
Router.select(cross_chain: true)  # => :xochi
Router.select(privacy: :stealth)  # => :xochi
Router.select()                   # => :x402

# Wire auto-pay into agent HTTP backend
plugin = AgentPlugin.auto_pay(
  wallet: Raxol.Payments.Wallets.Env,
  ledger: ledger_pid,
  policy: SpendingPolicy.dev(),
  agent_id: :my_agent
)
```

## Architecture

- `Raxol.Payments.Protocol` -- behaviour for payment protocol detection + signing
- `Raxol.Payments.Wallet` -- behaviour for key management
- `Raxol.Payments.Router` -- protocol selection + settlement routing
- `Raxol.Payments.PrivacyTier` -- trust score to tier mapping
- `Raxol.Payments.Zksar` -- attestation proof verification
- `Raxol.Payments.Xochi.Stealth` -- ERC-5564/6538 implementation
- `Raxol.Payments.Mandate` -- Xochi delegation envelope (EIP-712-signed, per-request)
- `Raxol.Payments.Mandate.Store` -- singleton ETS + optional DETS holder for envelopes
- `Raxol.Payments.Req.Mandate` -- Req plugin attaching `X-Xochi-Delegation` on outbound Xochi calls

See [Agentic Commerce docs](../../docs/features/AGENTIC_COMMERCE.md) for the full design.
