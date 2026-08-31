# Web3 upstream survey: what raxol_web3 can draw from

Companion to ADR-0032. Surveyed 2026-08-31. Every "verified live" entry below was
confirmed by completing a real MCP handshake or an HTTP request on that date.

Verdicts are the point of this document:

- **PROXY**: free enough to wrap as a runtime backend through `mcp_proxy`
- **PORT**: licence permits reusing the design; we reimplement in Elixir
- **AVOID**: dead, licence-hostile, or gated behind a paid key

## The short version

Three findings reorder the plan.

1. **SQD Portal has an official MCP server**, MIT and genuinely keyless (no account, no
   OAuth, no signup), covering EVM, Solana, Bitcoin, Substrate, and Hyperliquid in one
   backend. It is the single best PROXY target.
2. **Tron is the best-served chain in the survey, not the worst.** TronGrid and TronScan
   both run keyless hosted MCP servers, verified live returning real mainnet data. TronGrid
   additionally exposes 33 `eth*` JSON-RPC shims, so TVM can be read through an EVM-shaped
   surface.
3. **Canton is far less blocked than first assessed.** An MCP exists (ccscan), a
   permissively licensed client exists (Noves, MIT), and the Splice Scan API is Apache-2.0
   with 79 documented paths. The earlier "no verified public API" reading was too
   pessimistic.

## Ranked PROXY targets

| Rank | Server | Endpoint | Licence | Key | Tools | Verified live |
| ---- | ------ | -------- | ------- | --- | ----- | ------------- |
| 1 | SQD Portal MCP | `portal.sqd.dev/mcp` | MIT | none | 28 | stateless, 2026-07-28 revision |
| 2 | TronGrid MCP | `mcp.trongrid.io/mcp` | none (hosted) | none | 149 | `ethBlockNumber` returned `0x51dc4bb`; TRC-20 balance returned real data |
| 3 | TronScan MCP | `mcp.tronscan.org/mcp` | none (hosted) | none | 119 | `getNewestBlock` returned 85836989 |
| 4 | mcpdotdirect/evm-mcp-server | self-host | MIT | optional | 25 | 60+ EVM networks, 382 stars |
| 5 | ccscan Canton MCP | `ccscan.xyz/mcp` | closed | free account | 13 | `tools/list` open, `tools/call` returns `account_required` |
| 6 | SUN.IO MCP | `mcp.sun.io/mcp` | none (hosted) | none | 41 | stateless; Tron DEX data |

## PORT references, by licence

| Project | Licence | What to take |
| ------- | ------- | ------------ |
| `helius-labs/core-ai` | MIT | **The facade design.** 10 router tools for all of Solana, dispatching on params rather than one tool per RPC method. Direct prior art for our normalized contract |
| `canton-network/splice` | Apache-2.0 | The Scan API OpenAPI spec, 79 paths. Generate our Canton client from it |
| `aztec-scan/chicmoz` | Apache-2.0 | 51 REST routes; the durable self-host path for Aztec |
| `Noves-Inc/canton-mcp` | MIT | 9 Canton tools including `resolve_party`, `get_holdings`, `get_transactions` |
| `BofAI/mcp-server-tron` | MIT | Self-hostable Tron, ~60 tools, clean `--readonly` read/write split |
| `mcpdotdirect/evm-mcp-server` | MIT | EVM tool taxonomy, the community baseline |
| `strangelove-ventures/web3-mcp` | Apache-2.0 | Cross-VM normalization across ETH, SOL, Cardano, XRP, BTC |
| `IBM/mcp-context-forge` | Apache-2.0 | Gateway patterns: failure counting, token backends, conflict strategies |
| `docker/mcp-gateway` | MIT | Collision handling, reserved names, isolated capability validation |

## AVOID

| Project | Reason |
| ------- | ------ |
| `blockscout/mcp-server` | `LicenseRef-Blockscout` from 2026-05-15. Restricts SaaS and commercial use, forbids distributing derivative works, and the licensor may change terms at any time without notice. Do not port code, and do not mirror the tool taxonomy |
| `covalenthq/goldrush-mcp-server` | Archived 2026-02-20 |
| `chainstacklabs/rpc-nodes-mcp` | Archived 2026-04-09 |
| `MoralisWeb3/moralis-mcp-server` | No LICENSE file, so all rights reserved. Ten months stale |
| `openSVM/solana-mcp-server`, `wowinter13/solscan-mcp`, `AztecProtocol/mcp-server` | No LICENSE file |
| `transatron/awesome-tron-mcp` | No licence, and requires a TronGrid key anyway |
| `fbsobreira/gotron-mcp` | LGPL-3.0 copyleft; incompatible with a permissive Elixir library |
| Ponder, Goldsky, Envio | Their MCP servers are documentation search only, with no data surface |
| Dune Sim | Shut down 2026-08-01 |

## Wire-level findings that constrain `mcp_proxy`

These came off the wire during live handshakes, not from documentation, and they are the
reason `mcp_proxy` needs per-backend policy rather than one global setting.

1. **Three incompatible session models across three servers.** TronGrid is stateful and
   concurrency-safe (six parallel calls on one session all returned 200). TronScan is
   stateful and **concurrency-hostile**: two parallel calls on one session returned 500 for
   both, reproducibly, while sequential calls immediately after succeeded and the session
   survived. ccscan is fully stateless and issues no session at all. A backend therefore
   needs a declared concurrency policy of `:pooled`, `:serialized`, or `:stateless`. Fanning
   out across a single TronScan session fails 100% of the time.
2. **SSE framing differs between servers.** TronGrid emits `data: {...}` with a space after
   the colon; TronScan emits `data:{...}` without one. A strict parser breaks on one of them.
   `Accept: application/json, text/event-stream` is mandatory, and responses come back as
   either SSE frames or plain JSON depending on the server.
3. **Tool-count blowup justifies the facade.** TronGrid's 149 tools plus TronScan's 119 come
   to 268 tools for a single chain, and TRON's own documentation concedes the TronGrid server
   consumes a large share of the context window. Helius independently reached the opposite
   design at 10 router tools for all of Solana. That is the strongest available evidence that
   a normalized contract beats pass-through aggregation.

## What generalizes across VM families

Evidence-backed revision to the backend contract. Three of the original eight required
callbacks do not survive contact with non-EVM chains.

**Fully general, keep required**: `chain_info`, `get_transaction`, `list_transactions`.

**General, but the specified return type is wrong**:

- `block_height`: the unit differs and the finalized split is first-class outside EVM.
  TronGrid ships 26 parallel `solidity*` tools purely to expose the irreversible-node view.
  Solana counts slots, which skip, so height is not slot. Canton has no height at all, only a
  chain head sequence and a mining round. Return `{height, finalized_height, unit}` where unit
  is one of `:block`, `:slot`, `:offset`, `:round`. A bare integer silently lies on two of our
  four target families.
- `address_info`: only works if the address is opaque. Tron has dual Base58 and hex encoding.
  A Solana address may be a wallet, a token account, a PDA, or a program. **Canton has no
  addresses at all, it has party IDs** (`Alice::1220abcd`), which is why ccscan's tool is
  `get_party` and Splice's path is `/v0/acs/{party}`. Rename to `account_info(account_ref)`
  over an opaque tagged ref.
- `list_transactions`: the operation generalizes but **pagination does not**, and this is the
  least portable thing in the contract. TronGrid uses a fingerprint plus `min_timestamp`;
  TronScan uses `start` and `limit` with a hard `start + limit <= 10000` ceiling; Solana uses
  signature cursors; ccscan uses date windows; Splice uses a POST after-cursor; Aztecscan uses
  height ranges. Take and return an opaque cursor, and never expose an offset or page number.

**Demote to optional**:

- `get_block`: **Canton has no blocks.** None of Splice's 79 Scan paths return one, and the
  nearest primitives are rounds and updates. On Solana an empty or skipped slot is a valid
  success rather than an error. Requiring this forces two of four families to fake it.
- `list_token_transfers`: clean on EVM and TVM, absent elsewhere. On Solana transfers are
  instructions inside a transaction rather than events, and recovering them needs a parser,
  which is precisely what Helius meters at 100 credits per call. On Aztec private notes are
  unobservable by construction.

**Keep required, define the empty case**: `token_balances` returns `[]` on UTXO chains and
covers public state only on Aztec. Tron alone has three token standards, TRC-10 keyed by a
numeric ID rather than an address, so the token identifier must be a tagged type rather than a
bare address.

Net: **six required callbacks and two optional**, not eight required.

## Identifier and naming conventions

There is no schema convention for blockchain data in MCP. The de facto pattern is a single
tool with a `chain` discriminator, expressed as a slug plus numeric ID.

CAIP-2, CAIP-10, and CAIP-19 are stable, well adopted outside MCP (MetaMask, WalletConnect,
Ledger, ITSA), and essentially unused inside it. CAIP-363 adds a chain wildcard (`eip155:_`)
that expresses "this account across every EVM chain", which is exactly the indexer-agnostic
query. Adopting CAIP for identifiers is a cheap, defensible differentiator. Accept slug and
numeric aliases on input, because every existing agent has learned them from other servers,
and canonicalize on ingest, since CAIP-19 does not mandate canonicalization and naive string
equality produces false negatives on hex case variance.

Tool names follow SEP-986: 1 to 64 characters, alphanumerics plus `_`. Avoid `.` and `/`
entirely, since the `/` allowance is contested by a competing proposal and some clients reject
`.`. Client-side case folding is a documented hazard, so collision checks must be
case-insensitive.

## Serving posture for a free public instance

The shared upstream pool is the biggest operational risk: anonymous traffic carries no client
identity a provider can throttle fairly, so an abusive client can get our upstream key
suspended and take the service down for everyone.

Modelled on Exa, which is the best-documented free public MCP server:

- Two tiers from day one. Anonymous, keyed by IP, with a tight sliding-window rate and a daily
  cap. An optional client key swaps the rate-limit key from IP to key ID and raises the limit.
- **Bring-your-own upstream key as a first-class feature.** It converts the most expensive
  users into zero-marginal-cost users, and it is the only durable answer to both the shared
  pool problem and Blockscout's mandatory-key migration.
- Weight the limit per tool by upstream cost. A block-height read and a historical backfill
  must not draw from the same bucket.
- Cache aggressively and advertise freshness honestly through the `ttlMs` and `cacheScope`
  fields the current spec requires on list results.
- Return 429 with `Retry-After` and a JSON-RPC-compliant error body that names how to
  authenticate. A documented failure mode is a client silently hitting an anonymous quota and
  reporting a confusing error.
- Guard against agent retry storms by making non-retryable errors read as terminal, and by
  deduplicating identical calls within a short window.

## Unverified

Recorded so none of it is mistaken for settled: TronGrid and TronScan free-tier QPS (TRON's
documentation explicitly refuses to publish numbers and warns against hardcoding them, so the
commonly cited figures are historical rather than authoritative); whether a TronScan key raises
limits, since their MCP documentation host is Cloudflare-blocked from our network; ccscan rate
limits, since the plans endpoint is itself account-gated; SQD Portal rate limits, which are
undocumented; SQD network coverage, where the README, docs, and changelog disagree, so resolve
it at runtime through `portal_list_networks` rather than hardcoding; the licences of the hosted
Tron MCPs and ccscan, which have no repositories, so terms of service govern and PROXY-only is
the safe reading; and whether SEP-986 is merged as normative spec text or merely accepted.
