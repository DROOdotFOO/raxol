# ADR-0033: Indexer-agnostic web3 data surface (`raxol_web3`)

## Status

Proposed, 2026-08-31. Scoping only: no implementation has landed. The chain coverage matrix
below was verified by live probe on that date, and the licence findings were verified by
diffing `LICENSE` across upstream release tags.

Builds on the MCP stack (ADR-0012, `raxol_mcp`), the agent Action surface
(`Raxol.Agent.Action`), and the payment rails that own every chain reference in the repo
today (`raxol_payments`, `raxol_earn`).

## Context

Raxol settles real money across chains. `raxol_payments` runs Xochi cross-chain intents over
five EVM chains plus Robinhood Chain (4663), and `raxol_earn` sells offerings on Base and
operates an EVM-to-Tron relay rail. The product pulling on this is an FX dark pool, where
Tron carries disproportionate weight because it holds the largest share of USDT supply.

We asked Blockscout to add Tron, Canton, Solana, and Aztec support. They declined: they
cannot index anything non-EVM today, and they will not start without a funded, scoped
agreement with each respective chain team. That answer is structural rather than a matter of
resourcing. Blockscout's indexer is shaped around EVM semantics (accounts, logs, receipts,
internal transactions from debug traces) and cannot be pointed at Tron's TVM, Solana, a Daml
ledger, or Aztec. So the coverage we need is not purchasable, and no single vendor has it.

Three facts from our own codebase sharpen the problem.

### Gap 1: there is no block-explorer client at all

Blockscout appears in this repo only in four comments recording that a constant was verified
on-chain through it. Etherscan appears only as a map of URL prefixes for building
human-readable links, and that map is copied into four places: the `raxol_earn.order.ex` Mix
task and three live-gate tests. All four copies carry the same five chains, so none of them
covers chain 4663 or Tron.
Every on-chain read in the repo is a hand-rolled `eth_call`, `balanceOf`, or `eth_getLogs`.

Anything needing historical transfers, token lists, or verified-contract ABIs has nowhere to
go today.

### Gap 2: five parallel RPC configuration conventions

The repo resolves an RPC URL five different ways: `RPC_<NAME>` in `payments/accounting.ex`,
`DERIVE_RPC_<chain_id>` in `xochi/capacity_deriver.ex`, `ORDER_RPC_<chain_id>` in the order
task, `XOCHI_ORDER_RPC_<chain_id>` in the live gates, and `GATE_RPC_<chain_id>` in
`scripts/run_live_gates.sh`, plus `RAXOL_ACP_RPC_URL` for the solver. A comment in
`xochi/pull_preflight.ex` already acknowledges the split, and a test asserts that no gap
message hardcodes either name.

Chain 4663 has no public RPC default anywhere in library code. The only URL lives in a shell
script.

### Gap 3: two read paths that cannot share code

`Raxol.Payments.ChainReader` is a read-only behaviour (`get_receipt/3`, `get_balance/3`,
`get_erc20_balance/4`) whose own moduledoc explains that it hand-rolls a small `Req` adapter
purely because aliasing `raxol_earn`'s richer `Onchain.RPC` would be a dependency cycle. Two
JSON-RPC clients therefore exist in the same subsystem, documented as deliberate rather than
accidental. That is a symptom of the read layer sitting at the wrong level of the graph.

### The licence finding that reframes the approach

The obvious plan was to fork Blockscout's MCP server and extend it. That plan is dead.
Blockscout relicensed the entire stack in April and May 2026:

| Repository | Last freely licensed tag | Licence after |
| ---------- | ------------------------ | ------------- |
| `blockscout/mcp-server` | v0.15.0 (2026-03-03), MIT | `LicenseRef-Blockscout`, effective 2026-05-15 |
| `blockscout/blockscout` | v10.2.6 (2026-04-15), GPL-3.0 | proprietary from v11.0.0 (2026-04-22) |
| `blockscout/blockscout-rs` | (previously MIT) | `LicenseRef-Blockscout`, effective 2026-04-22 |

The Blockscout Software Licence permits modification for internal use only, forbids providing
derivative works to any third party without a commercial licence, explicitly reaches hosted
and SaaS offerings, and is revocable by the licensor at any time. A public fork is not
available to us, and the revocation clause alone disqualifies it as a dependency for anything
we intend to maintain.

The reframing: forking was the wrong instinct anyway. Consuming a public REST API carries no
licence obligation, so pointing our own Elixir client at Blockscout's `/api/v2/*` endpoints
sidesteps the question entirely. The MIT-licensed v0.15.0 tag remains available as a design
reference for tool taxonomy and pagination strategy, since MIT is irrevocable for copies
already distributed.

The hosted MCP service is closing on the same trajectory, which settles the question of
whether we could simply proxy it. Probing `mcp.blockscout.com` on 2026-08-31 returned two
notices in the response envelope: a free session budget of **10 tool calls**, and

> Starting 10/08/2026, all requests to the Blockscout MCP server will require a PRO API key
> for authorization.

A ten-call session budget already rules the hosted server out as a backend for anything
real, and in roughly five weeks it stops serving unauthenticated traffic at all. The REST
API is a separate surface and remains open today, but the direction of travel is one way,
so the fallback paths in the coverage matrix below are load-bearing rather than defensive.

## Decision

Build the aggregation layer ourselves, in Elixir, split across two packages along the line
separating domain-free protocol plumbing from chain knowledge.

### 1. `Raxol.MCP.Aggregator` lands in `raxol_mcp`

Three directions of tool conversion exist in the repo today, and one is missing:

| From | To | Mechanism |
| ---- | -- | --------- |
| Agent Actions | LLM tool loop | `Action.ToolConverter.to_tool_definitions/1` |
| Upstream MCP server | LLM tool loop | `Action.Dynamic.from_client/3` |
| Raxol capability | MCP client | hand-written `tool_def` maps plus `Registry.register_all/2` |
| Upstream MCP server | MCP client | does not exist |

That last row is the aggregation primitive. It is small: call `Client.list_tools/2`, map each
result into a `Raxol.MCP.Registry.tool_def()` whose callback is `Client.call_tool/4`, and
namespace it through the existing `Client.tool_name/2` (which already produces
`mcp__<server>__<tool>`). `Raxol.MCP.Client` supplies subprocess spawning, the initialize
handshake, and tool listing.

It belongs in `raxol_mcp` beside `Client` and `CircuitBreaker` because it carries no chain
knowledge and is useful to any consumer that wants to re-serve an upstream server's tools.

Lifecycle and admission control are copied from the existing session-scoped loader rather
than reinvented: `Raxol.Agent.Code.McpLoader.Janitor` for process ownership (it monitors the
owner and kills clients plus their linked ports on owner death, with no cleanup function to
forget), and its `admit/1` bounds of at most 16 servers plus a name regex, because every
accepted server mints an atom and spawns an OS process.

Two protocol facts bound how much machinery this layer should grow.

First, MCP defines a strict one-to-one client-to-server relationship in which the host, not
any server, aggregates context across servers, and its design principles state that servers
should not see into each other. An aggregating server is protocol-legal, since it is simply a
server to its client and a client to its backends, but it is a community pattern rather than
a blessed one, and no specification section describes it.

Second, and more consequentially, **the protocol went stateless on 2026-07-28, and that is
the current specification rather than a proposal.** SEP-2575 removes the `initialize`
handshake and `notifications/initialized`; SEP-2567 removes protocol-level sessions and the
`Mcp-Session-Id` header; `server/discover` is now a method servers MUST implement; `ttlMs`
and `cacheScope` are required on every list result; `Mcp-Method` and `Mcp-Name` headers are
required on Streamable HTTP posts so gateways can route without parsing bodies. SSE
resumability, `ping`, and `logging/setLevel` are gone.

This is a strong result for us downstream and a real cost upstream, and the asymmetry is the
architecture:

- **Downstream we are a modern-only server.** The public surface is genuinely stateless, so
  any node answers any request with no session affinity and no shared session store. That is
  statelessness at the protocol layer, and it is narrower than a claim that nothing is shared.
  Two things sit outside it, both keyed by upstream origin rather than by caller: the
  rate-limit buckets and the response cache. Both are node-local ETS, which is right on one
  node and under-counts on several, since N independent buckets spend N times the upstream
  budget. Whether a fleet shares them, and how, is left open below with the hosted-instance
  question. The protocol layer still gives close to the ideal shape for a free public service
  on the BEAM: no session store, and shared state that is small, coarse, and tolerant of
  staleness.
- **Upstream we must be a dual-era client.** Most indexer MCP servers are still legacy, and a
  modern client talking to a legacy server fails. TronGrid and TronScan were both confirmed
  stateful and return 400 without a session header, while SQD Portal and ccscan are already
  stateless. So the gateway must probe each backend, cache its era per origin, and hold
  legacy session state itself.

`raxol_web3` is therefore the stateful-to-stateless boundary: stateless downstream, stateful
upstream, with one supervised process per legacy backend holding that session behind a
stateless request path. That is an ordinary OTP shape, which is a substantive reason to build
this in Elixir rather than anywhere else.

### 2. `raxol_web3` becomes a new layer below `raxol_payments`

Placing chain code in `raxol_mcp` was considered and rejected on two grounds. `raxol_mcp`
depends on only `raxol_core` and `jason`, and main `raxol` depends on `raxol_mcp`, so chain
adapters there would push `req` and every backend into the dependency footprint of every
raxol install. More decisively, the three modules we most want to reuse all sit downstream in
`raxol_payments`, so reaching them from `raxol_mcp` is a cycle.

The resolution inverts the relationship. Reads are more fundamental than payments, so the
read layer belongs underneath them:

```
raxol_mcp      --> raxol_core, jason               (gains Aggregator)
raxol_web3     --> raxol_core, raxol_mcp, req
raxol_payments --> raxol_web3
raxol_earn     --> raxol_payments, raxol_web3
```

`raxol_mcp` is required rather than optional. Two of the chains that motivate this ADR are
served primarily by upstream MCP servers, TronGrid for Tron and ccscan for Canton, so
`Raxol.MCP.Client` sits on the critical path of the coverage matrix, and
`Raxol.MCP.CircuitBreaker` is what the router's failover is built on. Making either
conditional ships a build whose primary Tron path is absent and whose dead backends are
retried on every call. The footprint cost is one Elixir package: `raxol_mcp`'s own runtime
dependencies are `raxol_core` and `jason`, and `raxol_payments` already declares both, so
nothing new enters the payments tree. The direction stays acyclic, since `raxol_mcp` does not
depend on `raxol_web3`.

Four modules move down, unchanged in behaviour, with deprecated delegating shims left in
`raxol_payments` for one minor version:

| Module | Why it moves |
| ------ | ------------ |
| `Raxol.Payments.ChainReader` and its `JSONRPC` and `Stub` implementations | It is already the read behaviour, and the cycle it was written to dodge stops existing once the read layer sits below both packages |
| `Raxol.Payments.Tron.Address` | A complete, dependency-free Base58Check codec with tests. The Tron backend needs it |
| `Raxol.Payments.Pxe.Client` and `Pxe.Schemas` | The Aztec seam |
| `Raxol.Payments.Poll` | A chain-agnostic polling loop with a wall-clock budget, 83 lines and no dependency beyond the standard library. Reusing it from below would be a cycle, so it moves. All 17 call sites are in `raxol_payments` |

### 3. The backend contract

`Raxol.Web3.Backend` follows the repo's established adapter shape: a `{module, state}` handle
as in `ChainReader`, a capability-declaring callback as in `Raxol.Earn.ProviderAdapter`'s
`supported_chain_ids/1`, and a self-identifying zero-arity callback as in
`Raxol.Gateway.Adapter`'s `platform/0`.

The contract is **six required callbacks plus eight optional**, down from the eight required
first drafted. Surveying what non-EVM chains can actually answer (recorded in the companion
survey) demoted two of those eight to optional:

Required: `chain_info/1`, `block_height/1`, `get_transaction/2`, `account_info/2`,
`list_transactions/3`, `token_balances/2`.

Optional, declared through `capabilities/1` and guarded by `Code.ensure_loaded?` plus
`function_exported?` wrappers per house convention: `get_block/2`, `list_token_transfers/3`,
`read_contract/2`, `contract_metadata/2`, `get_logs/2`, `resolve_name/2`, `list_nfts/2`, and
`raw_request/2`, which reaches endpoints the contract does not model through a per-backend
allowlist of read methods declared as a compile-time constant in the backend module. A method
outside that list is refused before any HTTP call is built, and no served tool or Action takes
a method name from the caller. Section 4 depends on this: an unbounded passthrough to a
JSON-RPC backend reaches `eth_sendRawTransaction`.

Three shapes are load-bearing, because the naive version silently lies on chains we actually
target:

- `block_height/1` returns `{height, finalized_height, unit}` where unit is `:block`,
  `:slot`, `:offset`, or `:round`. A bare integer is wrong on two of our four VM families:
  Solana counts slots that skip, and Canton has no height at all. Tron's own infrastructure
  makes the point by shipping 26 parallel `solidity*` tools purely to expose the irreversible
  view, so the finalized split is first-class rather than an EVM afterthought.
- `account_info/2` takes an opaque tagged reference, not an address. **Canton has no
  addresses**, it has party IDs, which is why its explorer's tool is `get_party`. Tron has
  dual Base58 and hex encoding, and a Solana account may be a wallet, a token account, a PDA,
  or a program.
- Pagination is an **opaque cursor** in both directions, never an offset or page number. Every
  surveyed upstream paginates differently, and one caps `start + limit` at 10000, so exposing
  an offset would leak a limit we cannot honour uniformly.

`get_block/2` is optional because Canton has no blocks: none of the Splice Scan API's 79 paths
returns one. `list_token_transfers/3` is optional because outside EVM and TVM it is not an
event but a parse, which is precisely the operation Solana providers meter most heavily.

Chains are identified by CAIP-2 strings. This is consistent with what exists, since
`Raxol.Payments.Assets.normalize_chain_id/1` already accepts `"eip155:8453"`. VM families
reuse the `:evm | :tvm | :svm` type already defined in `Raxol.Payments.Xochi.Capabilities`,
extended with `:aztec` and `:canton`.

`Raxol.Web3.Router` resolves a chain reference to a backend through an ordered fallback chain,
with per-backend health gated by `Raxol.MCP.CircuitBreaker`. That gating is unconditional,
because `raxol_mcp` is a required dependency under decision 2. There is no build of this
package in which failover silently degrades to retrying a hard-down primary on every call.

Reference implementations ship in `lib/`, not `test/`, matching `Adapter.InMemory`,
`ProviderAdapter.Mock`, and `ChainReader.Stub`. No mocking library is introduced.

### 4. The served surface is read-only by construction

Agent Actions are the primary surface, and MCP `tool_def` maps are written directly. The
existing `Raxol.MCP.AgentBridge` is not used: it has no caller anywhere in the repo, it drops
the `sensitive` flag instead of emitting an annotation, and it formats results with
`inspect/2` rather than JSON.

Every tool in this package is a read, so the server runs under a nil authorizer on stdio. The
enforcement that makes that safe lives in this package rather than in the server.
`Raxol.MCP.Server.refuse_unguarded_sensitive_tools!/2` raises at boot only when a registered
tool is annotated sensitive through `ToolDef.sensitive?/1` and no `:authorizer` is configured,
and the `tools/call` backstop keys off the same predicate. An unannotated tool passes both
checks unimpeded, so the annotation records an intent and enforces nothing against a write
tool that omits it.

Three things carry the constraint instead:

- Every callback in the backend contract is a read, and `raw_request/2` is bounded by a
  per-backend compile-time allowlist of read methods, so the passthrough is structurally
  incapable of reaching `eth_sendRawTransaction`.
- The registered tool set is asserted rather than assumed. A test enumerates the registry
  after `register_all/2` and fails on any tool this package did not declare as a read, which
  is the check the server does not perform.
- Aggregated upstream tools are filtered against a per-backend allowlist before registration,
  since an upstream server's own annotations are untrusted (section 7).

Admitting a write tool later is therefore a deliberate act with a visible cost: it must carry
the `sensitive` annotation, which forces an `:authorizer` onto the whole server and changes
the deployment story for every consumer. Writes stay where they already are, behind the
spend-gated Actions in `raxol_payments`.

### 5. Chain coverage and data sources

Every entry marked verified was confirmed by live probe on 2026-08-31.

| Chain | Primary free source | Verified | Fallback | Binding constraint |
| ----- | ------------------- | -------- | -------- | ------------------ |
| EVM 1, 10, 137, 8453, 42161 | Blockscout REST `/api/v2/*` | eth and arbitrum returned 200; base and polygon returned 500; optimism redirects | Etherscan V2, then raw RPC | Public Blockscout sits behind Cloudflare, which answered a non-browser User-Agent with a 403 challenge page on probe day. We identify honestly and fail over rather than impersonate a browser, argued in section 7 |
| 4663 Robinhood Chain | `robinhoodchain.blockscout.com` | 200, live, 101 ms average block time | `rpc.mainnet.chain.robinhood.com` | Etherscan does not index 4663, so Blockscout is the only explorer source |
| chain registry | Chainscout `chains.blockscout.com/api/chains` | 200, 746 chains, no User-Agent issue | static table | The data is free to consume; the repository carries no LICENSE file, so the code is not forkable |
| Tron | TronGrid MCP (149 tools) and SQD Portal `tron-mainnet` | Both keyless and live: `ethBlockNumber` and a real TRC-20 balance returned; Portal reports `start_block: 0`, `real_time: true` | TronScan MCP (119 tools, keyless), `BofAI/mcp-server-tron` (MIT, self-host) | TronScan is concurrency-hostile (two parallel calls on one session both 500, reproducibly). TronGrid publishes no QPS figure and warns against hardcoding one |
| Solana | SQD Portal `solana-mainnet` | `start_block: 0`, `real_time: true` | public RPC | Public RPC allows 100 requests per 10 s per IP and 40 per method, so requests per second binds long before monthly volume does |
| Aztec | `api.aztecscan.xyz/v1/temporary-api-key/*` | 200 on mainnet for `l2/info`, `latest-height`, `blocks`, `txs` | self-hosted `chicmoz` (Apache-2.0) | The path segment is named temporary, so assume revocation. Public state only |
| Canton | ccscan MCP (`ccscan.xyz/mcp`, 13 tools) and Noves (MIT) | `tools/list` open and stateless; `tools/call` needs a free account | Splice Scan API (Apache-2.0, 79 paths), `api.cantonnodes.com` | No fully keyless path. Party IDs replace addresses and rounds replace blocks, so it exercises the optional half of the contract |

SQD Portal is the strongest finding: keyless, Apache-2.0 SDK, and full archives from genesis
with real-time heads for both Tron and Solana, which are exactly the two chains with no viable
free explorer API. It also covers all five of our EVM chains as a secondary path.

Four negative findings are recorded so nobody re-treads them. The Solana Foundation's official
MCP server at `mcp.solana.com` is a documentation and retrieval server with five tools and no
chain data, and it carries no LICENSE file; there is no official Solana chain-data MCP server.
Envio HyperIndex is source-available commercial software behind a EULA with an auto-accepting
contributor licence agreement, and HyperSync is closed, so it is unusable here despite
appearing open. Dune's Sim API shut down on 2026-08-01. `streamingfast/firehose-tron` is
Apache-2.0 and is the genuine open-source Tron indexer, but it requires running a Tron node
plus the full firecore pipeline, which is far heavier than calling SQD, so it is a contingency
rather than a starting point.

### 6. What is reused, and what is not

A free-tier aggregator is constrained by rate limits, caching, and clean failover. Every
primitive for those already exists in the repo, and three of the five are reachable from the
graph in decision 2. One is a cycle against it, and one sits above this layer. Each is
resolved here rather than deferred to implementation:

| Need | Where it lives today | Resolution |
| ---- | -------------------- | ---------- |
| Upstream MCP clients | `raxol_mcp`, as `Raxol.MCP.Client` | Reused. Spawn, handshake, `list_tools/2`, `call_tool/4`, `tool_name/2` |
| Backend health | `raxol_mcp`, as `Raxol.MCP.CircuitBreaker` | Reused. ETS-backed `check/3`, `record_success/2`, `record_failure/3` |
| Confirmation polling | `raxol_payments`, as `Raxol.Payments.Poll` | Moves down, a fourth entry in the decision 2 move table |
| Response cache | `raxol_agent`, as `Raxol.Agent.Cache` | Rebuilt as `Raxol.Web3.Cache`: the same four callbacks, ETS adapter in `lib/` |
| Free-tier budgets | `raxol_core`, as `Raxol.Core.TokenBucket` | Reused. ETS-backed `take/3`, `peek/3`, `retry_after/3`, keyed per upstream origin |

The first two rows are why `raxol_mcp` is required rather than optional, as set out in
decision 2. `CircuitBreaker` is 155 lines of public ETS with no owning process, so it costs
nothing to carry; its `key()` type widens by one variant for backend origins, an additive
change inside `raxol_mcp`.

`Poll` moves for the same reason `ChainReader` does, and it is the one primitive whose reuse
in place would be an outright cycle: decision 2 declares `raxol_payments --> raxol_web3`, so
calling it from here is `raxol_web3 -> raxol_payments -> raxol_web3`, the defect this ADR
exists to remove. Moving is cheap. It is chain-agnostic, 83 lines with no dependency beyond
the standard library, and all 17 of its call sites are in `raxol_payments`, which keeps a
delegating shim like the other three movers.

`Raxol.Agent.Cache` stays where it is. `raxol_agent` depends on main `raxol`, so consuming it
would pull the framework and the agent runtime underneath a read-only package, which is the
objection this ADR already raises against siting the backends in `raxol_payments`. Moving it
instead is a different size of change from the four above: a behaviour plus ETS and Postgrex
adapters, with 56 call sites inside a package this ADR otherwise never touches. Lifting it
into `raxol_core` is the right eventual move and is deliberately not made here.
`Raxol.Web3.Cache` copies the shape exactly (`get/2`, `put/4`, `delete/2`, `flush/1`, lazy
expiry, a TTL of `0` meaning no expiry) so the two converge cheaply when someone makes it.

`Raxol.Core.TokenBucket` is reused, having been fixed rather than routed around. When this
decision was first drafted the limiter was `Raxol.RateLimit` in main `raxol`, and it was
rejected for two independently sufficient reasons: it sat above this layer, and it was a
fixed-window counter behind one global `Agent` with no caller anywhere in the repo, so it had
never been exercised against a real upstream limit. Both objections have since been removed at
the source. It now lives in `raxol_core`, which this package already requires, and it is a
genuine token bucket: capacity plus a refill rate, refill computed from elapsed monotonic time
with fractional tokens preserved, in a public ETS table with no owning process, committed with
`:ets.select_replace/2` so concurrent takes cannot over-admit. Rate limiting here must be a
token bucket rather than a window counter or retry-on-429, because TronGrid's 30-second burst
penalty turns both of those into a sustained outage, and a fixed window admits two windows
worth of calls across a boundary. The bucket is keyed per upstream origin, since the limits
being respected belong to the backend rather than to our callers, and capacity and refill rate
are passed per call rather than read from application environment, so one table carries a
different limit for each backend.

One further pattern is adopted by analogy: `Raxol.Agent.Backend.Resolver` tags each provider
with a billing tier and refuses to auto-select a metered one. The same rule applies to
indexers, so a free public endpoint is chosen automatically while a metered key is used only
when explicitly configured.

### 7. Security constraints on a bring-your-own-upstream instance

Two defining features of this package are also its attack surface: callers influence which
upstream is contacted, and upstreams supply text the model reads. Both bind on any deployment
that accepts a caller-supplied endpoint or key, hosted or local, so they are decided here
rather than deferred to whoever deploys it.

**Caller-influenced upstream targets are constrained before the request leaves the process.**
Bring-your-own upstream key is the durable answer to the shared-pool risk, and it means part
of the target (a URL, a host, a dataset name, a chain-to-endpoint mapping) comes from the
caller. On Fly.io the set reachable from inside our infrastructure includes the cloud metadata
endpoint at `169.254.169.254` and the whole 6PN private range, so an unconstrained target is
server-side request forgery from a credentialed, well-connected origin. Five rules apply to
every outbound request, upstream MCP backends included:

1. The scheme is `https`. Everything else is refused, `http` included.
2. The host is resolved before the connection is made, and every resolved address is checked
   against a reject set: loopback, link-local (`169.254.0.0/16` and `fe80::/10`), RFC 1918,
   unique-local `fc00::/7`, IPv4-mapped IPv6, and `0.0.0.0/8`. An IP literal is checked the
   same way, so skipping DNS skips nothing.
3. The checked address is the address dialled. Validating a hostname and then handing that
   hostname to the HTTP client re-resolves it and reopens the window, so the connection pins
   to the vetted address.
4. Redirects are not followed on a caller-influenced target. A 3xx returns an error, because
   following one re-runs target selection under the upstream's control.
5. Timeout, response-size ceiling, and concurrency are bounded per target, so a slow or
   unbounded upstream costs one request rather than the node.

`raw_request/2` is covered by all five, and additionally cannot name a method outside its
backend's read allowlist.

**Caller-supplied credentials are held in transit only.** A TronGrid, Blockscout PRO, or
Etherscan key handed to us is used for the life of one request and never reaches a log line, a
telemetry measurement, a cache key, or a durable store. The error path is where this leaks in
practice. The survey prescribes returning an error body that names how to authenticate, and
upstream error bodies routinely echo the failing URL with its query string, so upstream
failures are reconstructed from status plus a redacted reason rather than relayed. The repo
has the pattern already in the Telegram adapter's token-redacted `getFile` download.

**Aggregated upstream tool descriptions are untrusted instruction text.**
`Raxol.MCP.Aggregator` turns an upstream's `list_tools` result into locally served tool
definitions, so names and descriptions written by third parties become model-visible text in
an agent's tool list. TronGrid's 149 tools plus TronScan's 119 is 268 unreviewed descriptions
from two servers with no public repository, governed by terms of service rather than a
licence. The current specification says descriptions and annotations should be considered
untrusted unless they come from a trusted server, and section 5 already establishes that none
of these upstreams is. The `admit/1` bounds copied in decision 1 do not help here: 16 servers
and a name regex bound atom and process exhaustion, and a name regex says nothing about a
description. So:

- The default served surface is the normalized contract rather than pass-through. Upstream
  tools are a backend implementation detail, which is what the 268-tool context blowup argues
  for independently.
- Where pass-through is enabled it is per backend, opt-in, and restricted to a declared
  allowlist of tool names, with our own description text substituted for the upstream's.
  Upstream annotations are never promoted into ours.
- Upstream text that does reach a response travels in the result payload, never in a tool
  description or an annotation.

**We identify ourselves honestly to upstreams.** Public Blockscout sits behind Cloudflare,
which answered a non-browser User-Agent with a 403 challenge page on probe day. Sending a
browser User-Agent would defeat the access control of the same vendor whose licence terms this
ADR otherwise respects scrupulously, and it would be short-lived: Cloudflare bot detection
also reads TLS fingerprints and HTTP/2 frame ordering, so a User-Agent string is a snapshot
Blockscout can invalidate unilaterally. Blockscout is the primary source for five of seven
chains and the only explorer source for chain 4663, so a posture built on impersonation fails
everywhere at once when it fails. The client sends a truthful `raxol_web3/<version>`
User-Agent with a contact URL, treats a challenge response as backend-unhealthy so the circuit
breaker trips and the router fails over to Etherscan V2 or raw RPC, and self-hosting or a PRO
key is the supported path for callers who need the explorer surface at volume.

## Consequences

### Positive

- Non-EVM coverage becomes possible at all, which was the blocking constraint.
- No single indexer is load-bearing. Each chain has a primary and at least one fallback, and
  the router fails over on health in every build, since the circuit breaker arrives with a
  required dependency rather than an optional one.
- The licence exposure goes to zero. We consume public HTTP APIs and write our own Elixir.
- Gap 3 closes as a side effect. `ChainReader` stops needing its own `Req` adapter, and the
  two JSON-RPC clients in the payments subsystem can converge.
- Gap 2 becomes tractable. One resolver can absorb the five existing conventions, and chain
  4663 gains a library-level default instead of a shell-script constant.
- The read layer becomes testable without network access, through a `Stub` shipped in `lib/`.

### Negative

- A fourth package in the payments dependency chain, and four module moves that touch
  `raxol_payments` and `raxol_earn` call sites. `raxol_mcp` also becomes a transitive runtime
  dependency of `raxol_payments`, which reaches it today only at compile time through
  `raxol_agent`.
- One of the five primitives in decision 6 is rebuilt rather than reused. `Raxol.Web3.Cache` is
  a second cache behaviour of the same shape as `Raxol.Agent.Cache`, carried until one of them
  lands in `raxol_core`.
- We take on maintenance of adapters against seven external data sources whose rate limits and
  availability we do not control.
- Canton needs a free account for any actual data call, so it is the one chain where the
  zero-configuration promise does not hold.
- Upstream MCP servers disagree at the wire level. Of three surveyed, one is stateful and
  concurrency-safe, one is stateful and concurrency-hostile, and one is stateless, and two
  frame SSE differently. Each backend therefore needs a declared concurrency policy and a
  tolerant frame parser, which is real complexity in `mcp_proxy`.
- The public Blockscout instances proved unreliable during the survey, so per-chain health
  checking is required rather than optional.
- SQD is a concentration risk. It is the primary source for both Tron and Solana, its coverage
  of those two chains is documented as public beta, and Subsquid Labs was acquired by Rezolve
  AI in October 2025, so the free public Portal is a business decision that can change.
- The aggregating-server shape runs against the grain of the MCP security model, and the
  session concept it would lean on is being removed from the specification.
- Bring-your-own upstream makes us a credentialed outbound HTTP client under partial caller
  control, so the section 7 target constraints bind on every code path that builds a request,
  upstream MCP backends included. A backend that hand-rolls its own HTTP call is a security
  regression rather than a style problem.
- Identifying honestly to Cloudflare means the public Blockscout path can be refused outright,
  and the EVM row then degrades to Etherscan V2 or raw RPC without the explorer surface.
- Refusing pass-through aggregation by default means an upstream capability our contract does
  not model is unavailable rather than merely awkward to reach.

### Mitigation

- Module moves ship with delegating shims for one minor version, so no downstream call site
  breaks in the same release.
- Every chain keeps its fallback path exercised in tests rather than merely present, so a
  primary going away is a degradation instead of an outage. This matters most for Tron and
  Solana, where the fallbacks (TronGrid, TronScan, public Solana RPC) are the insurance
  against SQD concentration.
- Canton is sequenced last, and its account requirement is surfaced as a configuration
  prompt rather than a silent failure.
- Backend concurrency policy is declared data (`:pooled`, `:serialized`, `:stateless`)
  rather than an assumption, so a hostile upstream degrades to serialized rather than
  failing every fan-out.
- Bring-your-own upstream key is a first-class feature from day one, which is the only
  durable answer to both the shared-pool suspension risk and Blockscout's key migration.
- Every outbound request goes through one guarded client, so scheme, address, redirect, and
  redaction rules have a single enforcement site rather than one per backend.
- The address reject set and the redirect refusal are property-tested against IP literals,
  IPv4-mapped addresses, and a resolver that changes its answer between calls, because these
  checks fail open silently when they fail.
- Credential redaction is tested on the error path specifically, which is the path where it
  breaks.

### What this ADR does not decide

- Whether we operate a hosted public instance, and under what abuse controls.
- Whether `raxol_web3` is published to Hex, and at what version. It starts at `0.1.0` and
  standalone, outside the root `modular_packages` list.
- How the rate-limit buckets and the response cache are shared across a multi-node deployment.
  `Raxol.Core.TokenBucket` and the cache are node-local ETS, which is correct on one node, so
  this is settled with the hosted-instance question rather than ahead of it.
- Whether Canton warrants running our own super-validator scan infrastructure.
- Which read methods each backend admits to its `raw_request/2` allowlist. The allowlist
  mechanism is decided in section 3; the per-backend contents land with each backend.
- Any write or transaction-submitting tool. Those stay in `raxol_payments`.

## Alternatives considered

### Fork `blockscout/mcp-server` and extend it

Rejected on licence grounds. Only v0.15.0 and earlier are MIT, that tag is six months stale,
and everything after 2026-05-15 forbids redistribution and is revocable at will. Reimplementing
a Python server in Elixir from a stale tag yields a design reference, not a codebase.

### A thin gateway that only proxies existing free MCP servers

Rejected on coverage. It would deliver exactly what upstream already provides, and the chains
we actually need are the ones with no upstream server: Tron has third-party servers of
unverified tool surface, Canton has none, and Solana's official server carries no chain data.
The aggregator keeps `mcp_proxy` as one backend among several, so this option survives as a
component rather than as the architecture.

### Put everything in `raxol_mcp`

Rejected on graph position, as set out in decision 2. It would make the protocol package a
domain package, add `req` and every chain adapter to every raxol install, and create a cycle
against the three modules we most want to reuse.

### Put the chain backends in `raxol_payments`

Rejected because a read-only public server would then transitively depend on wallets, EIP-712
signing, spending policy, and the agent runtime. It also leaves gaps 2 and 3 unaddressed,
since the read layer would still sit above the code that needs it.

## Validation

Three claim classes carry this ADR, and all three are reproducible.

The licence findings are verified by diffing `LICENSE` between `blockscout/mcp-server` tags
v0.15.0 and v0.16.0, and by reading the current licence text at the repository root.

The coverage matrix is verified by re-running the keyless probes: `portal.sqd.dev/datasets`
and the per-dataset `metadata` and `head` endpoints, `chains.blockscout.com/api/chains`,
`api.aztecscan.xyz/v1/temporary-api-key/l2/info`, `robinhoodchain.blockscout.com/api/v2/stats`
with a browser User-Agent, and `api.cantonnodes.com/v0/round-of-latest-data`. That User-Agent
records how the one-off probe got past Cloudflare, and it is not the client's posture: the
shipped client identifies honestly and fails over instead, decided in section 7.
The stateless-protocol claim is verified by reading the specification revision named in the
URL. The 2026-07-28 architecture page states that MCP is a stateless protocol in which every
request is self-contained and carries its own protocol version and capabilities, and that
capabilities are declared per request against `server/discover`. The 2025-06-18 revision it
replaced still describes `initialize` and `Mcp-Session-Id`, so a citation that omits the
revision date proves the opposite of the claim. SEP-2575 and SEP-2567 are linked below.

A second survey pass resolved several earlier unknowns and is recorded in
`docs/proposals/web3-upstream-survey.md`. The TronGrid and TronScan tool lists are now
measured rather than claimed (149 and 119), both servers were confirmed keyless against live
mainnet data, and Canton turned out to have both an MCP server and an Apache-2.0 API
specification, so it is adapter work after all rather than indexer work.

Items that remain unverified and must not be treated as settled: TronGrid and TronScan
free-tier rate limits, since TRON's documentation deliberately declines to publish figures and
warns against hardcoding them; ccscan and SQD Portal rate limits, both undocumented, with
ccscan's plans endpoint itself account-gated; SQD network coverage, where the README, docs, and
changelog disagree, so it must be resolved at runtime rather than hardcoded; whether the Base
and Polygon Blockscout 500 responses are transient, since that rests on a single sample;
whether the Etherscan V2 free tier allows 5 or 3 calls per second, where sources disagree; and
the lifespan of the aztecscan temporary key path.

The hosted Tron MCPs and ccscan have no public repositories, so their terms of service govern
rather than a software licence. Treating them as PROXY-only, and never porting from their tool
schemas, is the safe reading. The same caution applies more sharply to Blockscout: its licence
restricts commercial and SaaS use and permits unilateral term changes, so the EVM backend
should be generated from the API surface rather than mirroring their tool taxonomy.

One prior defect must be encoded rather than rediscovered: Blockscout's token-list endpoint
under-reports holdings, so any gating decision must read `balanceOf` through `read_contract`
instead. This constraint currently survives only as an operator note, and it belongs in the
EVM backend.

## References

- `docs/proposals/web3-upstream-survey.md`: the per-upstream PROXY, PORT, and AVOID verdicts,
  the wire-level findings behind the concurrency policy, and the evidence for demoting
  `get_block` and `list_token_transfers` from required to optional
- ADR-0012: MCP as a rendering target
- ADR-0023: Unified messaging gateway, the closest structural precedent for a package built on
  a frozen adapter behaviour
- `docs/PACKAGES.md`: the canonical dependency graph as it stands today. It does not carry
  `raxol_web3`, and this pull request deliberately leaves it alone. Updating it is part of
  moving this ADR from Proposed to Accepted
- Blockscout Software Licence: `https://raw.githubusercontent.com/blockscout/mcp-server/main/LICENSE`
- MIT licence at the last free tag: `https://raw.githubusercontent.com/blockscout/mcp-server/v0.15.0/LICENSE`
- Chainscout chain registry: `https://chains.blockscout.com/api/chains`
- SQD Portal datasets: `https://portal.sqd.dev/datasets`
- Model Context Protocol architecture, 2026-07-28 revision, the current one:
  `https://modelcontextprotocol.io/specification/2026-07-28/architecture`
- SEP-2575, "Make MCP Stateless", which removes the `initialize` handshake:
  `https://github.com/modelcontextprotocol/modelcontextprotocol/issues/2575`
- SEP-2567, "Sessionless MCP via Explicit State Handles", which removes `Mcp-Session-Id`:
  `https://github.com/modelcontextprotocol/modelcontextprotocol/issues/2567`
