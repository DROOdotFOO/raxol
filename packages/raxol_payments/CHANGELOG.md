# Changelog

All notable changes to `raxol_payments` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Registered RAXOL on Robinhood Chain (`0xf447...53af`, 18 decimals) in
  `Raxol.Payments.Assets`, so the Xochi client sizes, resolves and classifies
  USDC/USDT/USDG->RAXOL legs.
- `Raxol.Payments.Prices.CoinGecko` prices EURe (USD quote, not dollar par)
  and RAXOL. Neither is a settlement-ledger stablecoin, so an unpriced leg
  reports `nil`, never $1.
- `Assets.parse_atomic/1` parses a positive atomic amount no wider than a
  uint256, and `Assets.to_decimal/1` converts an amount to a `Decimal`, taking
  an integer string of up to 78 digits through the integer (decimal 3's
  string parse stops at 34 digits).
- `Raxol.Payments.Assets` registers the non-USD stablecoins of ADR-0040:
  EURC on 1 and 8453, EURe on 1, 100, 137, 8453 and 42161, and ZCHF on 1 plus
  the CCIP-bridged contract on 10, 100, 137, 8453 and 42161, each at its
  on-chain decimals. EURe was previously registered on 1 and 42161 only, so
  elsewhere the lenient `decimals/2` scaled it at 6 instead of 18, off by
  10^12. `address/2` matches the mixed-case wire symbol `"EURe"`
  case-insensitively. EURe's legacy v1
  contracts resolve to `"EURe"` through `symbol_for/2` and are never returned
  by `address/2`, since they front the same balance as v2. Chain 100 (Gnosis)
  gains a name and its xDAI gas token. New `Assets.fx_peg/2` names a token's
  non-USD peg. None of these tokens is solver-fillable: EURe leaves
  `symbols/0`, `evm_tokens/0` and the Xochi settlement grid, where it was
  listed on Arbitrum, and `supported_chain_ids/0` and the capabilities
  fallback are unchanged.
- Registering them opens no fund-moving path. `ExecuteXochiIntent` and
  `ExecuteRelayTransfer` refuse a non-USD source, and both refuse a non-USD
  destination without a positive `min_to_amount`, as `{:unpriced_asset, detail}`,
  until an FX rate gates the conversion (ADR-0040 decision 7). Dollar spend caps
  would otherwise count them at par. A `min_to_amount` of `0` bounds nothing:
  Relay reads it as absent and Xochi refuses it. x402 refuses a challenge whose asset is a non-USD
  stablecoin, which the spend gate would otherwise reserve and charge at par.
- `ExecuteRelayTransfer` accepts `min_to_amount` and refuses a quote delivering
  less before the spend is authorized. It previously had no delivery floor, so
  a quote could deliver any amount.

- Euro and franc stablecoins can be priced in accounting (ADR-0040 decision 6).
  `RAXOL_FX_ENABLED=true` with `RAXOL_SLEUTH_API_KEY` and `RPC_BASE` or `RPC_ETH`
  puts `Raxol.Payments.Prices.FX` in front of `RAXOL_PRICE_SOURCE` in the
  `RebalanceMonitor` sweep and `mix raxol_earn.rebalance`: EURC, EURe and ZCHF
  are priced at the Chainlink rate for their peg when Sleuth's market price is
  within 100 bps of it, and `nil` otherwise. Enabling it without the key, without
  either RPC URL, or in a build without `raxol_web3` (an optional dependency,
  dropped under `HEX_BUILD`) refuses and names what is missing. Pricing only: no
  spend cap or delivery floor reads an FX rate.
- `SettlementLedger` aggregates carry `unpriced_count`: entries with a leg that
  neither `usdc_price` nor `price_fn` could price. Such a revenue used to drop out
  of `usd_revenue` without a trace, so a report with EUR legs read as smaller
  rather than as partial.
- Each `RebalanceMonitor` sweep reports margin. It prices
  `SettlementLedger.report/2` with the same `price_fn` that sizes refuels (FX
  in front of `RAXOL_PRICE_SOURCE` when enabled), emits the totals as
  `[:raxol, :payments, :margin]`, which the accounting sidecar logs as
  `payments.margin`, and keeps the per-corridor report for
  `RebalanceMonitor.margin_report/1`. Until now nothing in production read the
  report, so FX pricing reached only the native gas symbols a refuel asks for.
  The advice and the report fail independently, and an FX snapshot that raises
  leaves EURC, EURe and ZCHF unpriced, and the rest to `RAXOL_PRICE_SOURCE`,
  instead of aborting the sweep.
  `SettlementLedger.report/2` reads the ledger once instead of four times.

### Fixed

- Under decimal 3, an x402 or MPP amount string of 35 to 78 digits no longer
  raises `Decimal.Error` out of `Req.AutoPay`, and `SettlementLedger` no longer
  crashes (losing its table) recording such an amount: x402 and the ledger
  convert through `Assets.to_decimal/1`, MPP through the integer. The amount
  then reaches the policy and budget gates, which refuse it when a
  `SpendingPolicy` and ledger are configured.
- The FX `price_fn` answers EURC, EURe and ZCHF in any casing, as `Assets`
  does: `"EURE"` or `"eurc"` used to reach the fallback, which could price a
  euro at par, and a lowercase Sleuth listing could not veto. The degraded
  `price_fn` `Prices.FX` returns when the snapshot raises or the key is refused
  folds case the same way.
- `SettlementLedger`'s `usd_margin` is the sum of per-entry margins: each
  entry's basis net of its own gas, over entries that have both. It was the
  total spread (else the total fee) minus the total gas, which mixed
  populations: an entry whose euro leg was unpriced added its gas but not its
  revenue, and with no priced spread at all the whole basis switched to fees,
  so one EURe entry with a $5 fee read +$4 and adding a $0.000001 USDC spread
  flipped the total to about -$2. A recorded-but-unpriced entry now has no
  basis; only an entry whose legs were never recorded falls back to its fee.
- `min_to_amount` is read the same way by `ExecuteXochiIntent`,
  `ExecuteRelayTransfer` and `ExecuteDepositRoute`, through the new
  `Raxol.Payments.DeliveryFloor`. A value that is not a non-negative integer of
  atomic units (`"1e6"`, `"995000.0"`, `"-1"`, `"abc"`) is refused as
  `{:invalid_min_to_amount, value}`; it used to be read as absent, so a dollar
  destination got no floor at all. On an EURC, EURe or ZCHF destination a floor
  below a tenth of the source amount rescaled to the destination's decimals is
  refused as `{:implausible_min_to_amount, detail}`, which catches a floor
  written in the source's 6 decimals for 18-decimal EURe. A quote is checked on
  its own `min_to_amount` when it states one, the amount guaranteed after
  slippage, rather than on its `to_amount` estimate.
- `ExecuteDepositRoute` returned a verified Tron deposit address for an EURC,
  EURe or ZCHF destination with no delivery floor, so the payer could fund a
  quote stating any amount. It now takes `min_to_amount`, as
  `ExecuteRelayTransfer` does: a non-USD destination without a positive one is
  refused as `{:unpriced_asset, detail}` before any quote is fetched, and a
  quote stating less than a positive floor, on any destination, returns
  `{:delivery_below_floor, detail}` instead of a deposit address. This filters
  the quote before funding; it does not bound delivery, because the deposit
  attestation does not cover the amount and the floor is not sent to Xochi.
  The deposit instructions from `Protocols.Xochi.deposit_route_quote/3` now
  carry the quote's `min_to_amount`.
- `SettlementLedger`'s `unpriced_count` missed two kinds of entry that dropped
  out of the totals. A nonzero fee no price answered (an EURe fee) left
  `usd_fee` silently and now counts as unpriced; an entry still counts once.
  An entry missing a leg's amount or decimals left `usd_revenue` silently and
  is now counted in the new `recording_gap_count`, which is a recording
  problem, not a pricing one. `[:raxol, :payments, :margin]` carries it.
- `Prices.FX` no longer raises `MatchError` when `Raxol.Web3.FX.Sleuth.new/1`
  refuses the configured key (one with a CR, LF or space inside it). It logs
  the refusal, which names the argument and never the key, and leaves EURC,
  EURe and ZCHF unpriced for the sweep to count.
- The FX `price_fn` no longer lets Sleuth choose what it reprices. It answers
  exactly the symbols in the new `Assets.fx_pegs/0`, at the Chainlink rate for
  the peg registered there, and hands every other symbol to the fallback. A
  snapshot listing `ETH` with `pegCurrency: "EUR"` used to price ETH at the EUR
  rate (1.13 instead of 2500), and ZCHF relabelled `EUR` was priced at the EUR
  rate. A listing whose peg disagrees with the registered one, a symbol listed
  twice with any listing not `:ok`, a symbol missing from the snapshot, and a
  failed snapshot all leave the symbol `nil`, never the fallback.

- Unknown chains and tokens now fail closed on the Xochi path instead of
  being treated as EVM or 6-decimal (#1149). `ExecuteXochiIntent` refuses,
  before quoting, a source or destination token without registered decimals
  (`:route_unsupported`, `{:unknown_asset, _}`; `min_to_amount` does not waive
  it) and a non-positive `min_to_amount`, and routes with chain ids so a Tron
  leg is sent to Relay. `Xochi.Schemas.QuoteRequest.validate/1` refuses stealth
  settlement to any chain outside `Assets.evm_chain_ids/0`, on every quote
  path. `Xochi.Capabilities.vm_type/2` returns `nil` for an unlisted chain, and
  a chain with an unrecognised `vm_type` is dropped (matching is
  case-insensitive). New `Assets.fetch_decimals/2` is the strict lookup.
- Circle USDC on Ethereum, OP, Base and Arbitrum Sepolia is registered for
  decimals and symbol (not as a solver corridor), so testnet Xochi runs keep
  working under the strict lookup.
- An explicit `min_to_amount` on a same-asset Xochi corridor can only raise
  the automatic 80%-of-par delivery floor. It previously replaced it, so
  `min_to_amount: "1"` switched the theft backstop off.

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
