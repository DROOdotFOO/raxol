# ADR-0040: FX market data and rate sources

## Status

Accepted, 2026-09-30. Every upstream claim below was probed on that date, and the re-probe
commands are in "Validation". **Implemented 2026-10-01**: decisions 1 to 6 landed (the Assets
registration, `Raxol.Web3.FX.Sleuth`, `.Chainlink`, `.Quality` and `FX.price_fn/3`, the MCP
and agent surfaces with their wiring, and `Raxol.Payments.Prices.FX` in the `RebalanceMonitor`
sweep), followed by an adversarial review whose fixes are recorded in the decisions they
changed: the live corridor path and x402 refuse FX tokens, Relay and Xochi require a floor in the destination's units, the deposit route filters quotes against one,
the identity check is lazy and caches only a match (decision 2), the Sleuth decoder is
bounded, a 403 is a status (decision 3), the verdict compares the exact deviation (decision 4),
and the price closure answers only the registered symbols at their registered peg (decision
6). Decision 7 is not built.

Builds on [ADR-0033](0033-web3-data-surface.md) (the `raxol_web3` read layer and its
dependency direction), [ADR-0038](0038-guarded-outbound-client-evm-rest-backend.md) (the
guarded outbound client every request goes through) and
[ADR-0039](0039-required-callback-set-partial-sources.md) (what a backend is required to
answer). Nothing in those decisions changes.

## Context

ADR-0033 names an FX dark pool as the product pulling on the web3 read layer. Raxol still
models no currency but the dollar. Four facts from the code, all checked on 2026-09-30; the
file:line references in this section are to the tree as it was then, before any of this ADR
landed, and later changes have moved them:

1. **Nothing prices a non-USD stablecoin.** `Raxol.Payments.SettlementLedger` values every
   member of `@stablecoins` at `:usdc_price`, default 1 (`settlement_ledger.ex:106`,
   `457-482`). Its moduledoc says there is no price oracle. The only price abstraction is an
   untyped closure `price_fn :: symbol -> Decimal | nil`, built by `Prices.CoinGecko` (ETH
   and POL only) or `Prices.Static`, and selected by `RAXOL_PRICE_SOURCE`, whose allowlist is
   `coingecko | none` (`accounting.ex:90`).
2. **An unpriced leg vanishes without a trace.** `add_or_keep(acc, nil)` returns `acc`
   (`settlement_ledger.ex:561`), so a nil price drops the leg from the totals, and no counter
   records it. `gas_unknown_count` covers only missing gas.
3. **Spend caps ignore currency.** `Ledger.try_spend/5` compares a raw `Decimal` with
   `per_request_max`, `session_max` and `lifetime_max`. `policy.currency` is read only for
   display (`spending_status.ex:45`), so 100 EURC counts as 100 against a cap written in
   dollars. `ExecuteXochiIntent` has no on-client price for a cross-asset corridor
   (`execute_xochi_intent.ex:308-309`), and `SolverAgent` refuses any fee base outside
   `~w(USDC USDT USDG)` (`solver_agent.ex:603-615`) because there is no oracle.
4. **The solver already trades a euro token that this repo cannot scale.** The live Xochi
   capability matrix (`GET https://api.xochi.fi/api/capabilities`, `source: live`) lists
   `EURe` with 18 decimals on chains 1, 100 and 42161, plus a `USDC -> EURe` conversion pair
   (float, 50 bps max slippage, cross-chain only). `Raxol.Payments.Assets` does not know
   EURe. The strict path is safe by accident: `ExecuteXochiIntent` reads the strict
   `fetch_decimals/2` and refuses an unregistered token as `unknown_asset`. The lenient
   `decimals/2` falls back to `@default_decimals 6` for any unknown token, so
   `ExecuteRelayTransfer`, the settlement recorder, the rebalance advisor and the capacity
   deriver scale any EURe amount wrongly, by a factor of 10^12. And registering EURe
   naively would not be a pure fix: "unknown token" is today the only thing refusing it on
   three fund-moving paths, so registration alone would open them with no FX conversion
   behind them (decision 6).

### The market-data source

Sleuth (`sleuthintel.io`) built an FX stablecoin surface at our request, and we reviewed it
over four rounds between 2026-09-15 and 2026-09-30:

| Endpoint | Returns |
| -------- | ------- |
| `GET /api/mcp/fx/stables` | Paginated assets: `symbol`, `aliases`, `corridor`, `pegCurrency`, `pegMechanism`, `yieldBearing`, `priceUsd`, `pegTargetUsd`, `deviationBps`, `supplyUsd`, `volume24hUsd`, `partnerLiquidityUsd`, and more. The top level carries `asOf`, `refreshSec: 60`, `fxRatesUsd`, `fxRatesAsOf`, `fxRatesSource` and `fxRatesStaleAfterSec` |
| `GET /api/mcp/fx/stables/{symbol}` | One asset plus `topPools[]`: `chain`, `dex`, `pair`, `priceUsd`, `liquidityUsd`, `volume24hUsd` |
| `GET /api/mcp/fx/corridors` | Totals per peg currency, with `assetCount` |

The breadth is real: 335 assets across 28 corridors, with supply, volume, and a depeg screen
that already has a $1M supply floor. The surface is REST only. `POST /api/mcp` answers
`initialize` and `tools/list` with 405 and a message saying so, so `Raxol.MCP.Client` and the
planned `Raxol.MCP.Aggregator` cannot consume it.

Its FX rates cannot be the rate of record, and that was measured rather than assumed:

- **Stale beyond its own budget.** `fxRatesSource` is `open.er-api.com`, which refreshes about
  once a day. At 13:56Z, `fxRatesAsOf` was `00:02:31Z`: 13.9 hours old against
  `fxRatesStaleAfterSec: 14400`. Deviations were still computed against it, so the staleness
  field is informational only.
- **Off the market rate.** Sleuth's EUR rate was 1.134404. Chainlink EUR/USD on Ethereum read
  1.135505 at the same time, a gap of 9.7 bps. On 2026-09-15 a gap of the same size flipped
  EURC's deviation from +15 bps to -13 bps, a sign change on the signal itself.
- **Not its own cross-check.** Pool `priceUsd` in `topPools[]` is rounded to two decimals, so
  one step is about 88 bps. A pool-implied rate built from it cannot support a basis-point
  comparison.
- **Price freshness is not in the payload.** On 2026-09-15, `asOf` tracked the request clock
  while `priceUsd` stayed fixed across four samples. It has not been re-measured since, so the
  age of a `priceUsd` should be treated as unknown.

Two outliers show what an unverified verdict costs. REUR is a fiat-backed EUR token priced at
$4.13, reported at +26,407 bps, and with `supplyUsd` computed from that price it clears the $1M
floor and tops the depeg sort. Yield-bearing USDY and USYC sit at +1,473 and +1,387 bps by
design.

### The rate source

Chainlink publishes the fiat rates we need on-chain. It is free to read, it is read through the
`eth_call` path `Raxol.Web3.RPC` already guards, and its update rules are published. Read on
2026-09-30, with parameters from Chainlink's reference-data directory:

| Pair | Chain | Proxy | Heartbeat | Deviation | Read |
| ---- | ----- | ----- | --------- | --------- | ---- |
| EUR / USD | Base (8453) | `0xc91D87E81faB8f93699ECf7Ee9B44D11e1D53F0F` | 3,600 s | 0.10% | 1.135875 at 14:59:43Z |
| EUR / USD | Ethereum (1) | `0xb49f677943BC038e9857d61E7d053CaA2C1734C1` | 86,400 s | 0.15% | 1.135505 at 13:41:11Z |
| CHF / USD | Ethereum (1) | `0x449d117117838fFA61263B61dA6301AA2a88B13A` | 86,400 s | 0.15% | 1.19835106 at 13:45:35Z |
| L2 sequencer uptime | Base (8453) | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | n/a | n/a | answer 0 (up) since 2026-06-26 |

Every feed reported `decimals() = 8`, and `description()` matched its pair. The directory also
lists a second Ethereum EUR/USD proxy (`0xEbc15D318379D46542459b0Dd922aFE30db2292B`) and a
Base CHF/USD (`0x3A1d6444fb6a402470098E23DaD0B7E86E14252F`), both at 0.5% deviation. Those
are too coarse for a basis-point gate and are not used.

## Decision

### 1. FX is market data beside the chain backends, not a backend

The code lives in `raxol_web3` as `Raxol.Web3.FX.*`, and it does not implement
`Raxol.Web3.Backend`. ADR-0039 defines a backend as a source that answers `chain_info/1` and
`block_height/1` about one chain, and Sleuth answers neither, about any chain. Forcing it in
would mean stubs attached to a behaviour, which the repository rules forbid.

There is no `FX.Source` behaviour either. There is one market-data source. The second source
in this decision, Chainlink, answers a different question (the rate for one pair) with a
different shape, so a shared behaviour would have one implementation and one misfit. Tests
drive the concrete handles over recorded fixtures through `Raxol.Web3.HTTP`'s `:exchange`
option, so every request still passes the vet, cache, breaker and bucket stages, and no stub
module is needed.

### 2. Chainlink is the rate of record

`Raxol.Web3.FX.Chainlink` reads `latestRoundData()` through `Raxol.Web3.RPC.eth_call/4`, and
through it the guarded client, with RPC URLs taken from configuration. It never uses a default
baked into the module. USD is the identity rate, exactly 1, and is never read.

| Peg | Primary | Fallback |
| --- | ------- | -------- |
| EUR | Base EUR/USD | Ethereum EUR/USD |
| CHF | Ethereum CHF/USD | none |
| any other | none: the answer is `:no_rate` | |

A rate is usable only when all of the following hold. A failure on the primary moves to the
fallback, and a failure on both means no rate:

- `answer > 0`.
- `now - updatedAt <= heartbeat * 1.1`: 3,960 s for the Base EUR feed and 95,040 s for the
  Ethereum feeds. The margin absorbs block inclusion delay and nothing more.
- On Base, the sequencer-uptime feed answers 0 and has been up for at least 3,600 s since
  `startedAt`. A stopped sequencer freezes the price feed while its `updatedAt` still looks
  recent. Chainlink's L2 sequencer-feed documentation describes this failure mode.
- The feed's identity matched. `description()` must equal the expected pair and `decimals()`
  must equal 8. `Chainlink.new/1` does no I/O, so the check runs on the first `rate/2` that
  reads the feed; a match is cached for a day (ADR-0038's cache stage, keyed by origin, a
  digest of the route, meaning the RPC URL and the request headers, plus chain id, proxy and
  selector) and every other answer is re-read on
  the next call. A decodable answer that names another pair or another scale is
  `{:blocked, :feed_mismatch}` and is terminal, because a misconfigured address would
  otherwise answer, correctly, about a pair nobody asked about. An answer that does not
  decode, such as the `"0x"` a node returns for an address with no code when an RPC URL
  reaches the wrong chain, is `{:decode_failed, :identity}`: an ordinary failed read that
  moves to the fallback. The URL digest is a truncated SHA-256, so a provider key in the path
  never enters the cache key, and it is what stops one handle's verified identity from
  vouching for a handle on the same host whose path reaches another chain. Keying by origin
  alone let exactly that happen.

A usable rate carries its `precision_bps`: the feed's deviation threshold, 10 for Base and 15
for Ethereum. This is honest about what a fresh answer means. Between updates, a Chainlink
answer may sit up to its threshold away from the market without a new round. Decision 7
depends on that bound.

### 3. Sleuth is consumed as market data, through the guarded client

`Raxol.Web3.FX.Sleuth` is a struct with `@derive {Inspect, except: [:api_key, :http_opts]}`,
the pattern `Backend.Canton` uses for its key. Every call is `Raxol.Web3.HTTP.get/2`:

- **Authentication** is an `authorization: Bearer` header only. The API also accepts
  `?api_key=`, and we never use it, because a key in a query string reaches access logs and
  error bodies.
- **Rate limit** is `rate_limit: [capacity: 5, refill_per_second: 0.25]`, which is 15 per
  minute against a published `x-ratelimit-limit: 120`. `x-ratelimit-reset` is ignored: it
  went from 985 to 1215 between samples rather than counting down. A 429 trips the breaker
  through `HTTP.unhealthy_status?/1`, which is the existing policy.
- **Cache** is `ttl_ms: 60_000`, keyed by the fragment `{path, sorted_query}`. The key and
  headers never enter a cache key, which `HTTP` already guarantees. Sleuth answers
  `cache-control: private, no-store`. That directive governs shared and browser caches. A
  60-second in-process memo of data that is identical for every caller, matching Sleuth's own
  `refreshSec: 60`, is compatible with it. ETag revalidation is not used, because the `HTTP`
  cache has no conditional-request stage and a 60 s memo gets the same effect on one node.
- **Bounds** are `max_bytes: 262_144`. Measured bodies with identity encoding: partner snapshot
  3.3 KB, default list 50.7 KB, `limit=300` 147.9 KB, detail 4.0 KB, corridors 70.4 KB.
  `includeChains=1` with a large limit is refused by Sleuth (400) and never requested. The
  body bound does not bound what one number costs, so the decoder does: see Parsing.
- **Parsing** uses `Jason.decode(body, floats: :decimals)`, so a float never reaches a money
  path. `raxol_web3` gains `{:decimal, "~> 2.0"}` for this; today it has `decimal` only as an
  optional dependency of `jason`. A figure is `nil` unless it has at most 38 significant
  digits and an exponent within ±30, checked on the decoded struct before any arithmetic:
  `1e1000000` is nine bytes of JSON and a million digits after the first rounding. A list
  entry that is not a JSON object is skipped, a number included (`1.5` decodes to a
  `%Decimal{}` struct, which a `%{}` pattern matches). Every other field is typed and bounded:
  text at most 256 bytes with everything invisible stripped (control and format characters,
  line separators, variation selectors, Hangul fillers), codes (`corridor`, `pegCurrency`)
  printable ASCII, counts non-negative integers below 10^9, at most 32 string
  `aliases`, else `nil`. No list is decoded past a cap: `assets` past the requested `limit`
  (300 by default), `topPools` past 32, `corridors` past 64 with 400 corridor assets in
  total, and `fxRatesUsd` past 64 three- or four-letter codes, since a byte-bounded body of
  `{}` was 87,000 assets. A 200 that is not the documented envelope is never cached.
  Neither the decoder's rounding nor Chainlink's rate (built as `answer * 10^-8` without
  division) depends on a caller's `Decimal` context, and Quality refuses a non-finite rate.
  `Raxol.Web3.Serialize` renders a `Decimal` whose exponent is past ±30 in scientific form.
- **Arguments** are validated before any request is built: `sort` against an allowlist,
  `limit` within 1..300, `corridor` as three or four uppercase letters (`REAL` and `VAR`
  are published corridors), and a `stable/2` symbol as up to 24 letters, digits, `.` and
  `-` starting with a letter or digit, so it cannot be a `..` segment. The key is trimmed and
  must be visible ASCII. Sleuth now returns 400 for bad arguments, but a local refusal costs
  no token from the bucket.
- **Errors**: 401 maps to `{:upstream_refused, :auth}`, 404 to
  `{:upstream_refused, :not_found}`, 429 to `{:upstream_refused, :rate_limit}`, and 400 to
  `{:invalid_argument, name}` for the argument the request carried (`"query"` on `stables`,
  `"symbol"` on `stable`), or `{:http, 400}` on `corridors`, which carries none. A 403 is
  `{:http, 403}`, as `Raxol.Web3.Backend` documents
  it, because in front of a CDN it is as likely a challenge page as a refused key. Any other
  status is `{:http, status}`. No upstream body leaves the module (ADR-0038 decision 6).
- **Symbols** are canonicalized through a fixed map in `FX.Sleuth`: `EURE` and `MONERIUM` to
  `EURe`, and `FRANKENCOIN` to `ZCHF`. Sleuth's `aliases` field is carried through and not
  read. The canonical form is the symbol `Raxol.Payments.Assets` uses (EURe's on-chain
  `symbol()`, as Xochi publishes it; lookups are case-insensitive), so a result can be
  echoed back as a lookup key.

### 4. The verdict on each asset is ours

`Raxol.Web3.FX.Quality` recomputes the verdict rather than relaying Sleuth's. Sleuth's
`deviationBps`, `pegTargetUsd` and `fxRatesUsd` are returned to callers as informational
fields, and nothing in this repo computes from them.

    deviation_bps = (priceUsd / chainlink_rate(pegCurrency) - 1) * 10_000

Each asset gets exactly one status. The first matching rule wins:

| Status | When |
| ------ | ---- |
| `:yield_bearing` | `yieldBearing` is true. A yield token drifts above its peg by design, so no deviation is reported |
| `:no_rate` | No usable Chainlink rate exists for `pegCurrency` (decision 2), including every peg outside USD, EUR and CHF |
| `:suspect` | \|deviation_bps\| > 100, judged on the exact deviation (the verdict's `deviation_bps` is rounded half-even for display only, so 100.4 bps is suspect and shows as 100), whatever the `pegMechanism`, or no `priceUsd` to compare. A broken feed and a real depeg look the same here, and neither may be priced at its peg. REUR lands here at any sane threshold |
| `:ok` | Otherwise |

`:no_rate` replaces the plan's earlier `:stale_rate`, which was keyed to Sleuth's
`fxRatesAsOf`. Under that rule, a daily-refreshed source against a four-hour budget would have
marked every EUR asset unpriceable for about twenty hours a day.

### 5. Served surfaces

- **MCP.** `Raxol.Web3.MCP.FXTools` registers `web3_fx_stables`, `web3_fx_stable` and
  `web3_fx_corridors`, which keeps the package's `web3_` prefix. `Raxol.MCP.Registry`
  overwrites duplicate names silently (an ETS `:set` insert, `registry.ex:311-315`), so the
  prefix does real work.
  All three are `readOnlyHint: true` and `sensitive: true`, so the server refuses to boot
  without an authorizer (ADR-0033 decision 4). Every asset in a result carries its Quality
  status and the rate it was judged against. Corridor results omit the per-corridor `assets`
  list unless asked, because it accounts for most of the 70 KB.
- **Agent.** `Raxol.Agent.Actions.FX` is one `fx` tool with an operation enum (`stables`,
  `stable`, `corridors`), gated by `Raxol.Agent.Actions.Code.network_allow/1`. It reads
  `context[:fx_source]` and answers `{:error, :fx_not_configured}` when the key is absent,
  following `Actions.Web3`. One tool rather than three, for the context-window reason
  `Actions.Web3` records.
- **Wiring.** Before this ADR, nothing in production set `context[:web3_router]`; only
  `web3_test.exs:16` did. Both keys are injected together, from one configuration reader over
  `Application.get_env(:raxol_agent, :web3)` plus `RAXOL_SLEUTH_API_KEY`, at every context
  builder that feeds a tool loop:
  1. `Raxol.Agent.Code.App.run_context/2`, beside `maybe_add_skills`, with the Actions added
     to `default_actions/0` only when configured. This covers `mix raxol.code`, the SSH code
     server and tenants.
  2. `Raxol.Console.Boot.gateway_opts/5`, beside `put_skills_context/2`. This covers the
     gateway and the scheduler.
  3. `Raxol.Agent.Turn.build_context/2`, for self-improve turns and Symphony.
  4. The ACP `serve.ex` `turn_opts/1`.
  5. `SessionInbox.start_turn/2`, through the executor's `:context`.

  The reader resolves the configuration once, when the `raxol_agent` application boots, and
  caches it; every builder above reads that cache. A mistake (`fx:` without the key, a key
  `FX.Sleuth.new/1` refuses, a `:web3` or `fx:` that is not a keyword list, or `:web3` in a
  build without `raxol_web3`) refuses the boot and names what is wrong, never the key, rather
  than raising in every turn or inbox prompt that builds a context. The key is trimmed and
  read then, so changing it takes a restart.

  A native vendor-loop backend runs its own tool loop and executes tools out-of-process over
  MCP, where the context never arrives (`scheduler/fire.ex:73-79`). On that path the `fx`
  Action answers `:fx_not_configured`. That is an existing limit, and this decision does not
  change it.

### 6. Valuation in `raxol_payments`

- **Registry first.** `Raxol.Payments.Assets` registers every verified address in one change,
  with chain 100 (Gnosis) added to the chain tables:

  | Symbol | Chain | Address | Decimals |
  | ------ | ----- | ------- | -------- |
  | EURC | 1 | `0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c` | 6 |
  | EURC | 8453 | `0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42` | 6 |
  | EURe | 1 | `0x39b8B6385416f4cA36a20319F70D28621895279D` | 18 |
  | EURe | 100 | `0x420CA0f9B9b604cE0fd9C18EF134C705e5Fa3430` | 18 |
  | EURe | 137 | `0xE0aEa583266584DafBB3f9C3211d5588c73fEa8d` | 18 |
  | EURe | 42161 | `0x0c06cCF38114ddfc35e07427B9424adcca9F44F8` | 18 |
  | EURe | 8453 | `0xbf6e2966A9C3D99C9E4D069E04f7Bdb9C8aa762C` | 18 |
  | ZCHF | 1 | `0xB58E61C3098d85632Df34EecfB899A1Ed80921cB` | 18 |
  | ZCHF | 8453, 42161, 10, 137, 100 | `0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553` | 18 |

  EURe's v1 addresses (1: `0x3231Cb76718CDeF2155FC47b5286d82e6eDA273f`, 100:
  `0xcB444e90D8198415266c6a2724b7900fb12FC56E`, 137:
  `0x18ec0A6E18E5bc3784fDd3a3634b31245ab704F6`) are recognized by `symbol_for/2` and never
  returned by `address/2`. On each chain the v1 and v2 contracts report the same
  `totalSupply`, because they are one balance behind two addresses, so summing both would
  double it. EURC has no native issuance on 42161, 10, 137 or 100. The EURC-named token on
  Optimism is a bridged representation and is not registered.

  The tokens live in their own `@fx_stables` table, not in the solver-fillable
  `@evm_tokens`. `symbols/0`, `evm_tokens/0` and `supported_chain_ids/0` are therefore
  unchanged, and with them `Xochi.Capabilities.fallback/0`, the capacity deriver and the
  stealth chain check. `Assets.fx_peg/2` names a token's non-USD peg.

  Registration must not open a fund-moving path, because until now "unregistered" was the
  only thing refusing these tokens on three of them. Each keeps its refusal, now with the
  reason stated as `{:unpriced_asset, detail}`: `ExecuteXochiIntent` and
  `ExecuteRelayTransfer` refuse a non-USD source, and a non-USD destination without a
  positive `min_to_amount` (with one, it is allowed, as an unregistered destination
  already was on the Xochi path; `0` bounds nothing and counts as absent). The TransferCore
  corridor gate never counts them fillable, whether the static fallback or Xochi's live
  capability matrix (which lists EURe) is deciding, so the refusal holds with the
  stablecoin corridor allowlist off. x402 cannot move them, because it signs under the USDC
  EIP-712 domain (`UsdcDomains.lookup/1`), but its spend gate scales by registered decimals
  and would reserve and charge them at par, so it refuses a challenge whose asset has an
  FX peg. `ExecuteDepositRoute` moves nothing itself, but the deposit address it returns is
  what the payer funds, so it applies the Relay rule: a non-USD destination needs a positive
  `min_to_amount`, and a quote stating less returns no address. That is a filter on an
  unattested quote before funding, not a bound: the deposit attestation does not cover
  `to_amount`, `min_to_amount`, the destination or the recipient, and the floor is not sent
  to Xochi.

  All three read `min_to_amount` through `Raxol.Payments.DeliveryFloor`. A value that is not
  a non-negative integer of atomic units is refused, not read as absent. On a non-USD
  destination it must be in that token's units: below a tenth of the source amount rescaled
  to the destination's decimals, it is refused as a wrong-units floor (a 6-decimal floor on
  18-decimal EURe bounds 10^-12 of what it looks like). A quote is judged on the lowest
  amount it states: its `to_amount`, its own `min_to_amount` when it gives one, and on the
  Xochi intent path the `toAmount` the wallet signs, read as `EIP712` encodes it (a declared
  field left null or out signs as 0). Every amount must fit a uint256, and `EIP712` refuses one
  that does not rather than sign its low bits. The re-quote an expired execute leads to is
  held to the same floor and method checks before it is signed. A floor checked only on the
  stated minimum let a quote advertise a high minimum beside a 1-wei estimate.

  This lands first and does not wait on the rest. It removes the 10^12 misscale in context
  item 4 whether or not any FX pricing is enabled, and moves no new funds.

- **Price closure.** `Raxol.Web3.FX.price_fn/3` returns a `symbol -> Decimal | nil` closure, built from one partner snapshot and one rate read per registered peg, in front of a fallback `price_fn`. Its second argument is the registered `%{symbol => peg}` table, `Assets.fx_pegs/0`, which `Raxol.Payments.Prices.FX` passes in because `raxol_web3` does not depend on `raxol_payments`. `Prices.FX` builds the closure from the accounting opts, and `RebalanceMonitor` composes it in front of `RAXOL_PRICE_SOURCE` on each sweep. `RPC_BASE` and `RPC_ETH` are reused for the feeds.
  The same closure prices both halves of the sweep: refuel sizing, which asks only for native
  gas symbols, and `SettlementLedger.report/2`, which is where euro and franc legs are read.
  Each sweep emits the report's totals as `[:raxol, :payments, :margin]`, which the accounting
  sidecar's `LoggerHandler` logs, and keeps the full per-corridor report for
  `RebalanceMonitor.margin_report/1`. The monitor runs only with `XOCHI_SOLVER_ADDRESS` set;
  ledger-only mode has no margin report.
  Each registered symbol is priced at the Chainlink rate for its REGISTERED peg when every
  listing of it in the snapshot names that peg and is judged `:ok` against it, and is nil
  otherwise: absent, relabelled, vetoed, unrated, or because the snapshot failed or raised.
  Accounting is priced at the rate of record, and Sleuth's role is to veto, not to price: its
  payload chooses neither which symbols are repriced nor at which rate. A registered symbol is
  never handed to the fallback, which might price a euro at par. Symbols are compared in
  ASCII upper case (`Assets.fold_symbol/1`), so any casing of a registered symbol is answered
  by the closure, any casing of a listing can veto, and a lookalike (`EURı`) folds onto
  nothing. `pegCurrency` is compared upper-cased too. A peg's rate state is logged when it
  changes, per route: no usable rate or a fallback feed with Chainlink's reason, a
  `{:blocked, _}` refusal at warning, and the return to the primary. Every other symbol is
  delegated to whatever `RAXOL_PRICE_SOURCE` selects, so ETH and POL pricing is unchanged
  whatever the snapshot says. It is enabled by `RAXOL_FX_ENABLED=true` and
  follows the accounting env contract: set-but-empty is unset, an unknown value raises, and
  nothing is parsed while `RAXOL_ACCOUNTING_ENABLED` is not `"true"`. Setting it in a build
  without `raxol_web3` raises and names the variable.
- **Unpriced is counted.** `SettlementLedger` gains `unpriced_count`, beside
  `gas_unknown_count`: entries with a leg, or a nonzero fee, that no price answered, each
  counted once. Entries whose revenue cannot be computed because a leg's amount or decimals
  were never recorded are a different problem and are counted in `recording_gap_count`. EUR
  and CHF tokens never join `@stablecoins`, because that set means "valued at `usdc_price`".
- **Dependency.** `raxol_payments` takes `raxol_web3` as an optional dependency, dropped under
  `HEX_BUILD` exactly as `raxol_agent`'s `web3_dep/0` does (`raxol_agent/mix.exs:87-93`).
  There is no cycle: `raxol_web3` depends on `raxol_core` and `raxol_mcp` only, and ADR-0033
  already declares this edge. The ADR-0033 module moves (`ChainReader`, `Poll`, `Pxe.Client`)
  have not happened, and nothing here depends on them.

### 7. Gating money on FX: decided, and deferred

No spend cap, delivery floor or fee base reads an FX rate in the change that implements
decisions 1 to 6. When one does, it converts a non-USD amount only when all of the following
hold, and refuses otherwise:

1. A usable Chainlink rate exists for the asset's peg (decision 2).
2. The asset's Quality is `:ok`, and its \|deviation_bps\| against that rate is at most 25.
   The band covers the feed's own precision bound (10 or 15 bps) plus a margin, and nothing
   else.
3. The Sleuth snapshot behind the verdict was fetched within the cache TTL, so no answer older
   than 60 s gates anything.

The consumers, when that change is made: `SpendGate.authorize/3` normalizes to USD before
`Ledger.try_spend/5`; `ExecuteXochiIntent` derives a cross-asset delivery floor for `EURe <->
USDC`; `SolverAgent` admits EURe as a fee base; and `CorridorAllowlist` gains an EURe family
matching the live capability matrix. That change is also the one that lifts decision 6's
`{:unpriced_asset, _}` refusals, site by site, and no earlier change may. Sleuth alone never
gates, because nothing in its payload dates a `priceUsd`.

## Consequences

### Positive

- The 10^12 EURe misscale closes in the first change, independent of any FX work.
- Euro and franc stablecoins become priceable in accounting, with a rate that has a published
  update rule and a measurable age.
- Sleuth's breadth (335 assets, supply, volume, liquidity, corridor totals) reaches agents and
  MCP clients, with a verdict we can defend attached to every asset.
- An unpriced leg becomes a counted gap rather than a silently smaller total.
- The gate conditions are fixed before any gate exists, so the change that adds one argues
  about implementation rather than policy.

### Negative

- Two upstreams where there was none: a partner API with a key, and on-chain reads that need a
  configured RPC URL for chains 1 and 8453.
- CHF has one feed and no fallback, so ZCHF is unpriced whenever the Ethereum CHF/USD read
  fails.
- The Ethereum feeds' 24-hour heartbeat means a fresh answer can be up to 15 bps from the
  market without a new round. The 25 bps gate band spends most of its margin on that.
- Fiat FX markets close at weekends, and what the feeds answer then has not been measured
  here. The age rule cannot detect it, because the heartbeat keeps posting.
- Pegs outside USD, EUR and CHF are `:no_rate`: 25 of Sleuth's 28 corridors and 57 of its 335
  assets. Those assets are visible to agents and priced nowhere.
- `raxol_web3` gains a direct `decimal` dependency, and `raxol_payments` gains an optional
  dependency whose absence has to be handled at runtime.

### Mitigation

- The Assets registration ships as its own change, so the misscale fix does not wait on the
  rest. Its addresses and decimals were read on-chain on 2026-09-30 and re-read by the review
  (16 of 16 addresses and decimals, the three feeds and the sequencer); "Validation" gives
  the calls. `assets_test.exs` pins the table, which makes a change to it deliberate, but it
  is a copy of the table and does not re-read the chain.
- The feed identity check makes a wrong address a refusal on the first read, `{:blocked,
  :feed_mismatch}`, rather than a silent wrong rate.
- `:no_rate` is a status an operator can see, not a nil hidden inside a total, and
  `unpriced_count` makes its accounting cost visible.
- A pair gains a rate by adding a row to decision 2's table with its measured heartbeat and
  threshold. Nothing else changes.
- Weekend behaviour is measured before decision 7 is implemented, and the gate refuses
  conversion when the market is known to be closed if the measurement shows a gap.

### What this ADR does not decide

- Whether Sleuth's planned v2 indexer events (transfers, swaps and bridge settlements across
  Aztec, Tron and EVM) arrive as a chain backend, an event source, or webhooks. That is
  decided when they exist.
- Whether the rate-limit bucket is shared across nodes. It is node-local ETS, as ADR-0033
  leaves open.
- Whether the limit Sleuth publishes is per key or per IP. There is one key to test with.
- A rate source for any peg outside EUR and CHF.
- Whether FX data is served to a hosted public instance. Sleuth's key belongs to one
  operator, and ADR-0033's hosted-instance question is still open.

## Alternatives considered

### Sleuth's `fxRatesUsd` as the rate of record

Rejected on measurement: 13.9 hours old against its own four-hour budget, 9.7 bps from
Chainlink, and sourced from a free daily feed. Sleuth may move to an intraday source, and
decision 4 would then compare two rates rather than replace one. The rate of record would stay
on-chain, because an on-chain answer carries its own timestamp and needs no partner's
cooperation to verify.

### A pool-implied rate as the second source

Sleuth's `topPools[].priceUsd` is two-decimal, so it cannot support a basis-point comparison.
Reading a pool's `slot0` on-chain can: the hardening pass measured the Ethereum EURC/USDC pool
at 1.136326, 7.2 bps from Chainlink. It is rejected as the rate of record because it is one
venue's marginal price, movable within a block by anyone with the pool's depth. It remains a
candidate third input to decision 7 if two Chainlink feeds are ever not enough.

### Consuming Sleuth through `Raxol.MCP.Aggregator`

Not available: the JSON-RPC transport answers 405 by design. Pass-through would also violate
ADR-0033 section 7's rule that upstream tool descriptions are untrusted text, which is served
only through our own normalized definitions.

### Serving Sleuth's numbers directly

Rejected for the four reasons in "The market-data source". A tool that relays `deviationBps`
would have reported REUR as the largest depeg in the EUR corridor and EURC with the wrong sign
on 2026-09-15.

## Validation

Chainlink reads are reproducible with `eth_call` against any public RPC for chains 1 and 8453:
`description()` (`0x7284e416`), `decimals()` (`0x313ce567`) and `latestRoundData()`
(`0xfeaf968c`) on each proxy in the rate-source table. Heartbeat and deviation for each proxy
come from `https://reference-data-directory.vercel.app/feeds-mainnet.json` and
`feeds-ethereum-mainnet-base-1.json`. The sequencer feed's `latestRoundData()` answers 0 when
the sequencer is up, with `startedAt` as the time of the last status change.

Token addresses are reproducible with `symbol()` (`0x95d89b41`), `decimals()` and
`totalSupply()` (`0x18160ddd`) against each chain in decision 6's table. v1/v2 EURe equality
is the `totalSupply()` pair per chain: 3,688,620 on 1, 19,109,552 on 100, and 2,833,233 on 137,
as read on 2026-09-30.

The Sleuth findings are reproducible with a keyed `GET` of `/api/mcp/fx/stables`, comparing
the current time with `fxRatesAsOf` and `fxRatesStaleAfterSec`, and with the
`x-ratelimit-*` headers across two requests a few seconds apart. The Xochi claims are one
unauthenticated `GET https://api.xochi.fi/api/capabilities`: `capabilities.tokens` holds EURe
at 18 decimals on 1, 100 and 42161, `conversion_pairs` holds `USDC -> EURe`, and no entry of
`corridors` mentions EUR.

The decision itself is validated by three observable outcomes once implemented:
`Assets.decimals(1, "0x39b8B6385416f4cA36a20319F70D28621895279D")` is 18; `web3_fx_stables`
reports REUR as `:suspect` and USDY as `:yield_bearing`; and a settlement containing a leg
whose rate is `:no_rate` increments `unpriced_count` rather than shrinking `usd_revenue`.

## References

- [ADR-0033](0033-web3-data-surface.md): the read layer, its dependency direction, and
  section 7's treatment of credentials and untrusted upstream text
- [ADR-0038](0038-guarded-outbound-client-evm-rest-backend.md): `Raxol.Web3.HTTP` as the only
  way out of the package
- [ADR-0039](0039-required-callback-set-partial-sources.md): what a backend is, and why a
  market-data source is not one
- Sleuth manifest: `https://www.sleuthintel.io/api/mcp/manifest` (keyed)
- Chainlink EUR/USD and CHF/USD: `https://data.chain.link/feeds/ethereum/mainnet/eur-usd`,
  `https://data.chain.link/ethereum/mainnet/fiat/chf-usd`
- Chainlink L2 sequencer uptime feeds: `https://docs.chain.link/data-feeds/l2-sequencer-feeds`
- Circle EURC addresses: `https://developers.circle.com/stablecoins/eurc-contract-addresses`
- Monerium v2 contracts: `https://docs.monerium.com/contracts-v2`
- Frankencoin token: `https://frankencoin.com/token`
