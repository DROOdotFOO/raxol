# raxol_web3

Pre-alpha. The indexer-agnostic web3 read layer described by
[ADR-0033](../../docs/adr/0033-web3-data-surface.md), built on the guarded
outbound client of
[ADR-0038](../../docs/adr/0038-guarded-outbound-client-evm-rest-backend.md).

## What is here now

`Raxol.Web3.HTTP`: the guarded outbound client, and the only way out of this
package. One fixed, ordered pipeline:

    vet -> token bucket -> circuit breaker -> pinned dial -> bounded read -> redact

A backend that reaches for a stage directly skips the vet, the upstream's
budget and the health record, which is why the stages are documented as stages
rather than as a toolkit. Any status comes back as a response (classifying a
403 challenge page or a 200 carrying an authentication failure is a per-backend
judgement); what this module decides from a status is health, not success.
Errors name an origin by opaque id, never by host, because a per-account URL
names the account in its hostname and an error term travels into logs,
telemetry and model-visible text.

`Raxol.Web3.Dial`: the pinned dial. It connects to an `:inet` address tuple
while the hostname travels separately, so SNI, certificate verification and the
`Host` header all follow the name that was vetted rather than a name the
transport resolves for a second time. That is ADR-0033 section 7's third rule,
and this is its first implementation in the repository.

The dial holds no policy. Addresses reach it already vetted by
`Raxol.Core.Outbound`, and nothing there consults a resolver: the API takes
address tuples and refuses a name, which is what makes "the checked address is
the address dialled" a type-level property rather than a convention.

`Raxol.Web3.Exchange`: one request and one bounded response on a dialled
connection. Nothing below it bounds anything, so this loop owns four bounds: a
response-size ceiling, a `content-length` pre-rejection, a wall-clock deadline
re-checked before every `recv`, and a per-`recv` silence timeout. Owning the
loop is what makes the deadline cover the header phase, which a deadline
checked inside a stream callback cannot: no callback runs until the header
section is complete. Truncation is never a success, because the accumulator
starts incomplete and only the terminating response promotes it.

`Raxol.Web3.Tables` owns the rate-limit, circuit-breaker and origin tables, and
starts with the application. `Raxol.Web3.Origin` mints and resolves the opaque
ids. `Raxol.Web3.Redact` collapses a transport failure to an atom and strips a
query string from a URI.

`Raxol.Web3.Backend`: the chain-read contract, two required callbacks plus
twelve optional ones, with three shapes that are load-bearing because the naive
version lies on a chain we target: a height that names its unit and its
finalized split, an opaque tagged account reference (Canton has party ids, not
addresses), and opaque cursors in both directions.

Two required rather than ADR-0033's six, amended by ADR-0039. That set was
derived from what chains can answer, and the contract binds sources: a raw
JSON-RPC node has no method that lists by account, Aztec's public surface has
no account resource at all, and SQD Portal answers queries over block ranges,
so it reports no current balance and cannot look a Solana transaction up by
signature. What stays required is what a source knows about the chain rather
than about anything in it: which chain this is, and how far it has got. So
`get_transaction/2`, `account_info/2`, `list_transactions/3` and
`token_balances/3` are declared through `capabilities/1` like the other eight,
and `Raxol.Web3.Router.coverage/2` is how an operator sees what a chain
actually answers. A handle may also name its own source through `backend/1`,
so coverage reads `[:trongrid, :sqd, :tronscan]` rather than `[:tron, :tron,
:tron]` for a module carrying three upstreams.

### The backends

`Raxol.Web3.Backend.Blockscout`: the EVM backend, against `/api/v2/*`. Its
shapes are pinned by responses recorded from the live API, because the vendor
publishes no spec for this surface. `token_balances/3` reads the paginated
`/tokens`, not `/token-balances`, which returned 3.1 MB for one wallet.
`block_height/1` never mixes sources: both numbers from the node, or a height
from REST with finality explicitly `nil`.

`Raxol.Web3.Backend.JSONRPC`: a raw node, and the first partial source. It
answers the required two plus `get_transaction/2`, `account_info/2`,
`get_block/2`, `get_logs/3`, `read_contract/2` and `raw_request/2`, and
declines the rest because no `eth_*` method answers them without an index a
node does not have. It carries chain 4663's public RPC URL as a dated default,
which is what gives that chain a routable fallback now that its only explorer
serves challenge pages.

`Raxol.Web3.Backend.Solana`: two handles, an SQD Portal archive and the public
RPC. `unit: :slot`, and the slot is not the block height: measured on
2026-09-14 the two differed by 21,957,491 at one moment. The archive answers
the required two and nothing else, because a range query cannot look a
signature up or report a current balance; the node answers both, plus token
balances and a signature-cursor walk. A skipped slot is a success with a nil
hash rather than an error. An account carries its `kind`, because a token
account's lamport balance is its rent-exempt reserve and a caller reading it
as a wallet balance would be wrong by design.
Transaction reads are taken at `confirmed` and account reads at `finalized`,
per read rather than per handle, and the moduledoc carries the table and the
reason: a confirmed transaction exists and a fork can still drop it, so
`status: :success` is readable but is not settlement.

`Raxol.Web3.Backend.Tron`: three handles, TronGrid MCP, SQD Portal and
TronScan MCP, with declared concurrency per source (`:pooled`, `:stateless`,
`:serialized`). `finalized_height` comes from the irreversible view rather
than the head, which is what TronGrid's parallel `solidity*` tools exist to
expose. An account reference accepts Base58 and hex for the same account and
canonicalizes at the edge, so two encodings are one cache entry and one
answer. TRC-10 and TRC-20 balances are distinguishable without the token type
growing a field: a TRC-10 has no address and a numeric id, a TRC-20 the
reverse. TronScan's `start + limit <= 10000` ceiling travels inside the opaque
cursor and a walk that would cross it fails rather than rewinding.

`Raxol.Web3.Backend.Canton`: party ids instead of addresses, rounds instead of
blocks, and a POST after-cursor for the one paginated party-scoped read the
chain offers. `get_block/2` is not declared, because none of Splice's Scan
paths returns a block. Every declared read answers keyless from the scan host,
which corrects the survey's "no fully keyless path": only the ccscan
passthrough needs an account, and a missing credential is
`{:upstream_refused, :auth}` rather than a generic failure.

`Raxol.Web3.Backend.Aztec`: public state only, which is a property of the
chain rather than of the indexer. `token_balances/3`, `account_info/2` and
`list_transactions/3` are absent: private notes are unobservable by
construction, the public surface has no account resource, and the per-sender
filter that does exist would return a page missing every private transaction,
which is worse than no page. `block_height/1` takes the whole finality ladder
from one endpoint, because a height and its finalized half read from two
endpoints can invert. The `temporary-api-key` path is carried as dated data
and its revocation is a tested failover to a self-hosted instance, not a
comment predicting one.

`Raxol.Web3.MCPCall`: one stateless MCP `tools/call` on the guarded path, for
upstreams that need no session (SQD Portal, ccscan). A stateful upstream goes
through `Raxol.MCP.Client` instead, whose HTTP transport enforces the same
outbound rules. `Raxol.Web3.Tron.Address` is the Base58Check codec, a verbatim
copy of the `raxol_payments` one until ADR-0033 decision 2's move lands, so
that move is a delete rather than a merge.

`Raxol.Web3.Cursor`: opaque, MACed, and scope-bound. Opaque is not safe on its
own, because the decoded keys become upstream query parameters.

`Raxol.Web3.RPC`: the read-only JSON-RPC client, on the guarded path, with a
compile-time method allowlist. It is where the repository's two hand-rolled
JSON-RPC clients converge, not a third one.

`Raxol.Web3.Router`: resolves a chain reference and a callback to a backend,
healthy first, with failover. It consumes the circuit-breaker verdict the
outbound path already records rather than keeping a second opinion, and it
never writes health, so one bad response is not counted twice. Failover is
decided on the error: an error about the SOURCE (breaker, transport, timeout,
rate limit, unwell status, undecodable body) moves to the next backend, and an
error about the QUESTION (not found, unsupported account reference, invalid
cursor) is final, because asking another source gets the same answer and hides
the first. `coverage/2` reports which callbacks have a healthy source right
now, which is the question an operator has when an explorer starts serving
challenge pages.

A paging walk is pinned to the backend that started it. A cursor carries its
origin, so failing over mid-walk would leave the fallback with no usable
cursor: it would answer with its first page, and the caller would receive page
one labelled page two. An interrupted walk is an error the caller can restart;
a silently rewound one is not.

`Raxol.Web3.Backend.Stub`: a complete in-memory reference backend, in `lib/`
per ADR-0033's convention, so a consumer can exercise the contract and the
router's failover with no network and no fixtures. `:answers` injects a canned
result, including an error, into any callback.

`Raxol.Web3.Cache` and `Raxol.Web3.TTL`: the response cache, sitting between
the vet and the token bucket. Before the vet a hit would answer for a target
we had not checked; after the bucket it would spend a token for a request we
are not making. Keys are `{origin_id, fragment}` and the fragment comes from
the backend's endpoint and its declared parameters, never from the assembled
URI, because an API key travels as a query parameter on one of the upstreams
here. `TTL` holds the per-endpoint values, and has no entry for a height: a
cached height read beside a live finalized height is what produces
`finalized_height > height`.

`Raxol.Web3.MCP.Tools`: thirteen typed MCP read tools over a router.
`raw_request` has no tool, so no served path takes a method name from a
caller, which makes the chain operation structurally read-only. The tools are
nevertheless `sensitive: true` and require a server authorizer because a call
discloses query intent and may consume provider quota. Results go through
`Raxol.Web3.Serialize` as JSON rather than `inspect/2`.

The agent Action surface is `Raxol.Agent.Actions.Web3`, and it lives in
`raxol_agent` rather than here: `use Raxol.Agent.Action` is that package's
macro, and defining the tool here would pull the framework and the agent
runtime underneath a read-only package. It is one tool with an `operation`
enum rather than thirteen, because an Action sits in a coding agent's toolset
for the whole session and thirteen tool definitions in every prompt is a cost
paid by every turn, including the turns that never touch a chain.

## What is not here yet

`Raxol.MCP.Aggregator` (ADR-0033 decision 1) is not here: nothing in this
package re-serves an upstream's own tools, by design, and the aggregator is
what would. The `Raxol.Payments.ChainReader` migration that ADR-0033 decision
2 describes is also still ahead: `Raxol.Web3.RPC` is what it collapses onto,
and `Raxol.Web3.Tron.Address` is where that module's Tron codec lands.

Two contract questions are open and recorded in ADR-0039 rather than guessed
at here: whether `list_opts` grows a time or range window, which is what an
archive needs before it can answer an account-scoped list at all, and whether
`capabilities/1` should be probed rather than declared.

`mix test` excludes the live tests. `mix test --include live_web3` runs the
whole pipeline against the real upstreams, one describe block per backend, and
the Canton suite skips its credentialed half when no ccscan key is present
while still running its keyless half.

`raxol_web3` is not published to Hex. ADR-0033 leaves that open.
