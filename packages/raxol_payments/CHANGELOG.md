# Changelog

All notable changes to `raxol_payments` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Registered Monerium EURe on Arbitrum (`0x0c06...44f8`, 18 decimals) and
  RAXOL on Robinhood Chain (`0xf447...53af`, 18 decimals) in
  `Raxol.Payments.Assets`, so the Xochi client sizes, resolves and classifies
  USDC->EURe, EURe->RAXOL and USDC/USDT/USDG->RAXOL legs. `address/2` matches
  the mixed-case wire symbol `"EURe"` case-insensitively.
- `Raxol.Payments.Prices.CoinGecko` prices EURe (USD quote, not dollar par)
  and RAXOL. Neither is a settlement-ledger stablecoin, so an unpriced leg
  reports `nil`, never $1.
- `Assets.parse_atomic/1` parses a positive atomic amount no wider than a
  uint256, and `Assets.to_decimal/1` converts an amount to a `Decimal`, taking
  an integer string of up to 78 digits through the integer (decimal 3's
  string parse stops at 34 digits).

### Fixed

- Under decimal 3, an x402 or MPP amount string of 35 to 78 digits no longer
  raises `Decimal.Error` out of `Req.AutoPay`, and `SettlementLedger` no longer
  crashes (losing its table) recording such an amount: x402 and the ledger
  convert through `Assets.to_decimal/1`, MPP through the integer. The amount
  then reaches the policy and budget gates, which refuse it when a
  `SpendingPolicy` and ledger are configured.

### Security

- x402 and MPP challenges whose atomic amount is wider than a uint256 (more
  than 78 digits, or above 2^256 - 1) are rejected at parse time as
  `{:invalid_amount, _}`. No such amount can be signed. The bound is checked
  before the string is parsed, so a hostile server can no longer make the
  client parse a header-sized number, run a quadratic `Decimal.div` on it, or
  hand `on_confirm` and the telemetry logger a `Decimal` too wide for decimal
  3's 6_178-digit `to_string` limit (which raised, or detached the logger).
- Requires `decimal ~> 3.0` (was `~> 2.0`) for EEF-CVE-2026-32686 (unbounded
  exponent DoS). Decimal 3 defaults to the decimal128 context: precision 34
  (was 28), `emax: 6_144` / `emin: -6_143` with over/underflow signalled, and
  string parses reject more than 34 digits or an exponent past 6_144.

## [0.2.1] - 2026-09-09

### Added

- Accounting, fee-schedule, settlement-ledger, and rebalance-policy primitives
  for tracking and managing agent payment rails.
- Runnable agent-payment and privacy-mode examples.

### Changed

- Separated stealth recipient routing from shielded settlement semantics.
- Updated the `raxol_core` and `raxol_agent` requirements to the 2.7 release
  line.

### Fixed

- Bound Xochi quote signatures to the served EIP-712 domain fields.
- Corrected paymaster policy selection and tightened on-chain read boundaries.

### Security

- Bounded and redacted payment telemetry before durable persistence.

## [0.2.0] - 2026-07-11

### Added

- `Raxol.Payments.Mandate`: Xochi delegation envelope. EIP-712-signed
  per-request authorization from a Member to a specific agent wallet.
  Schema mirrors `xochi/packages/shared/src/eip712.ts` (snake_case
  fields, `string[]` scopes, chainId pinned to 1). Digest verified
  byte-for-byte against viem's `hashTypedData`. Functions:
  `build/1`, `typed_data/1`, `digest/1`, `sign/2`, `verify/1`,
  `to_envelope/1`, `from_envelope/1`, `compute_envelope_hash/1`,
  `expired?/2`, `covers_scope?/2`.
- `Raxol.Payments.Mandate.Store`: singleton ETS + optional DETS
  holder for signed envelopes. Indexed by `envelope_hash` (primary),
  `agent_wallet`, `human_wallet`. Optional persistence via
  `:mandate_store_path` in `Application` config. No consume semantics
  (Xochi enforces budgets server-side).
- `Raxol.Payments.Mandate.Check`: pure selector. Returns the
  soonest-expiring active Mandate that covers a given scope.
- `Raxol.Payments.Req.Mandate`: Req request-step plugin. Attaches
  `X-Xochi-Delegation` header on outbound Xochi-host URLs, mapping
  request path to scope (`/api/intent/quote` → `quote`,
  `/api/intent/execute` → `execute`, `/api/settlement/claim` →
  `stealth_claim`). Passes through unchanged on non-Xochi hosts or
  unrecognized paths.
- Agent Actions for Mandate lifecycle: `payment_create_mandate`,
  `payment_list_mandates`, `payment_revoke_mandate`. Local revoke
  only; Xochi's KV budget counter remains until `expires_at` (no
  server revoke endpoint per Xochi's locked design).
- Registered the `payment_execute_relay_transfer` and
  `payment_poll_relay_status` Actions in the default set
  (`Raxol.Payments.Actions.Payments.actions/0`); the Tron relay rail
  modules existed but were not aggregated.

### Changed

- Renamed the `payment_get_balance` Action to `payment_get_wallet_info`
  (module `GetBalance` → `GetWalletInfo`). It returns the wallet address
  and chain ID, not an on-chain balance, so the old name was misleading.

## [0.1.0]

Initial release. Autonomous agent payment capabilities.

### Added

- `Raxol.Payments.Protocol`: behaviour for payment protocol
  detection + signing. Impls: `X402`, `MPP`, `Xochi`, `Riddler`.
- `Raxol.Payments.Wallet`: behaviour for key management. Impls:
  `Wallets.Env` (env var), `Wallets.Op` (1Password via GenServer).
- `Raxol.Payments.EIP712`: typed-data hashing for scalar types
  (address, uint256, bytes32, string, bool). Used by wallet impls and
  ACP memo signing.
- `Raxol.Payments.Req.AutoPay`: Req response-step plugin that
  handles HTTP 402 transparently. Detects protocol, checks spending
  budget, signs payment, retries.
- `Raxol.Payments.Router`: routes between protocols based on chain,
  privacy preference, and trust score. Same-chain 402 → x402/MPP;
  cross-chain → Xochi; privacy → Xochi.
- `Raxol.Payments.SpendingPolicy`: per-request/session/lifetime
  spending limits + domain allowlist + confirmation thresholds.
- `Raxol.Payments.Ledger`: ETS-backed spend tracking GenServer.
  Atomic `try_spend/5` prevents TOCTOU races. Sliding-window session
  budgets.
- `Raxol.Payments.SpendingHook`: CommandHook impl that gates
  payment commands against `SpendingPolicy` + `Ledger`.
- Agent Actions: `payment_get_balance`, `payment_get_quote`,
  `payment_transfer`, `payment_spending_status`,
  `payment_list_history`.
- `Raxol.Payments.Xochi.Stealth`: ERC-5564 / ERC-6538 stealth
  addresses (secp256k1, view tag scanning, domain-separated key
  derivation, meta-address encode/decode).
- `Raxol.Payments.Pxe.Client`: JSON-RPC 2.0 client for the Aztec
  Private eXecution Environment (shielded settlement).
- `Raxol.Payments.PrivacyTier`: Glass Cube model, 6 attestation-
  gated privacy tiers.
- `Raxol.Payments.Zksar`: ZKSAR attestation proof verification (6
  proof types) and `Zksar.TrustScore` (diminishing-returns
  aggregation).
