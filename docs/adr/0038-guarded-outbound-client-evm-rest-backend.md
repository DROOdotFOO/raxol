# ADR-0038: The guarded outbound client and the EVM REST backend

## Status

Proposed, 2026-09-13. Nothing is implemented; `packages/raxol_web3` does not exist.

This implements ADR-0033 decisions 3, 5, 6 and its §7, and it is the concrete answer to the
plan that ADR-0033 killed: forking Blockscout's MCP server is unavailable on licence grounds,
and its reframing was that "consuming a public REST API carries no licence obligation, so
pointing our own Elixir client at Blockscout's `/api/v2/*` endpoints sidesteps the question
entirely". This ADR specifies that client and the first backend on it.

Two classes of claim below are dated and reproducible. Library behaviour is cited to the
vendored source in `deps/` (req 0.7.4, finch 0.23.0, mint 1.10.0, per `mix.lock:86`, `:34`,
`:53`). Upstream behaviour was probed on 2026-09-13 with the honest User-Agent this ADR
mandates. Those probes resolve three items ADR-0033 listed as unverified and retire one of its
probe-day findings; see "Validation".

## Context

### Gap 1: the guard already exists once, privately, and is missing its hardest rule

`Raxol.Agent.Actions.Fetch` implements four of ADR-0033 §7's five rules, and implements them
well:

| §7 rule | Where | Note |
| ------- | ----- | ---- |
| 1. scheme check | `check_url/1` (`fetch.ex:228-240`) | allows `http` as well as `https`, so it is not the https-only rule |
| 2. reject set on resolved addresses | `resolve/1` (`:262-283`), `getaddrs/2` (`:286-291`), `blocked?/1` (`:302-356`) | both families; covers IPv4-mapped (`:322`), IPv4-compatible (`:323`), IPv4-translated (`:331`), NAT64 (`:335-336`), 6to4 (`:341`), a bitmask clause for `fc00::/7`, `fe80::/10`, `ff00::/8` and Teredo (`:343-352`), CGNAT `100.64/10` (`:309`); a non-tuple fails closed (`:355`) |
| 3. dial the checked address | **nowhere** | see below |
| 4. no redirect following | `redirect: false` (`:662`) with a manual per-hop re-check, `check_hop/2` (`:246-254`) yielding `{:blocked_redirect, host}`, `@max_redirects 5` (`:136`) | |
| 5. bounded time and size | `collect/3` (`:384-409`), `@default_max_bytes 524_288` and `@max_max_bytes 2_097_152` (`:133-134`), `@total_timeout_ms 15_000` (`:135`), `retry: false` (`:663`) | |

Rule 3 is absent, and the module says so itself (`fetch.ex:44-51`, verbatim):

> the guard resolves the name and the transport resolves it again, so a record that changes
> between the two (DNS rebinding) is not covered. Closing it means connecting to the
> already-checked address and carrying the hostname only in SNI/Host, a transport rewrite this
> tool does not perform.

So the one rule ADR-0033 states as "the checked address is the address dialled", and whose
mitigation list requires a property test against "a resolver that changes its answer between
calls", is implemented in no module in this repository. Decision 3 below is that transport
rewrite.

The guard is also structurally unavailable to `raxol_web3`: it is private to one agent tool
with exactly two callers (itself, and `Actions.WebSearch` through `Fetch.transport/1`,
`fetch.ex:707-711`), and it lives in `raxol_agent`, which sits above main `raxol`. Reaching it
from a package that ADR-0033 decision 2 places *below* `raxol_payments` would invert the graph
that ADR exists to fix.

### Gap 2: every other outbound call in the repo is unguarded

Roughly 51 files call `Req`, and `:inet.getaddrs` appears in exactly one of them
(`fetch.ex:287`). No other module resolves, vets, or size-bounds an outbound target. The two
JSON-RPC clients are the relevant example, since this package absorbs their job:
`ChainReader.JSONRPC` builds `[url:, headers:]` and passes **no timeout at all**
(`jsonrpc.ex:108-110`), while `Earn.Onchain.RPC` sets `receive_timeout: 15_000`
(`rpc.ex:83-89`). Neither sets `redirect:`, neither vets an address.

Credential redaction exists in two places: `Raxol.Telegram.HTTP.redact_transport_reason/1`
(`telegram/http.ex:139-142`), written because Mint's `{:invalid_request_target, "/file/bot<token>/..."}`
leaks a bot token into an error term, and a `[REDACTED]` substitution in
`metrics/cloud.ex:153-163`. There is no general helper, and the payments and earn error tuples
(`{:http, status, body}`, `{:transport, reason}`) pass raw upstream bodies through untouched.

### Gap 3: what the vendored libraries do and do not give us

Established by reading `deps/`, because this is where a plausible-sounding plan fails:

| Need | Mechanism | Citation |
| ---- | --------- | -------- |
| Dial an IP, verify the hostname | `Mint.HTTP.connect/4` `:hostname`, "Required when `address` is not a string" | `deps/mint/lib/mint/http.ex:204-205`, `:324-327`; `deps/mint/lib/mint/core/util.ex:7-18` |
| It reaches SNI, cert match, and Host | `default_ssl_opts/1` sets `server_name_indication: hostname`, `verify: :verify_peer`, and `add_verify_opts/2` derives the match function from the same value; the Host header derives from the hostname identity | `deps/mint/lib/mint/core/transport/ssl.ex:561-573`, `:449-457`, `:459-470`; `deps/mint/lib/mint/http1.ex:170-178`, `:1265-1278` |
| Pool keying | `%Finch.Pool{scheme, host, port, tag}`, and the tag is part of the key, so it is where a hostname can travel | `deps/finch/lib/finch/pool.ex:28-29`, `:143`; `deps/finch/lib/finch/request.ex:113-115` |
| `conn_opts` are per-pool, never per-request | only `:pool_timeout`, `:receive_timeout` and `:request_timeout` are read from request options | `deps/finch/lib/finch/http1/pool.ex:42-45`; `deps/finch/lib/finch.ex:879` |
| Req cannot carry a pinned dial | `finch_name_options/1` raises on `:finch` plus `:connect_options`, and discards pool options when `:finch` names an instance | `deps/req/lib/req/finch.ex:546-548`, `:577-585` |
| Refuse redirects | `redirect: false`; default is follow, up to 10 | `deps/req/lib/req/steps.ex:89`, `:1462`, `:1465-1467` |
| Cap bytes | nothing built in; `Finch.stream_while/5` plus `{:halt, acc}` | `deps/finch/lib/finch.ex:816-822`; `Finch.stream/5` cannot abort, `:700-702` |
| Bound a whole response | a budget decremented before every `recv`, which is what `:request_timeout` does on HTTP/1 | `deps/finch/lib/finch/http1/conn.ex:298-301`, `:313-323` |

Six findings from that reading change the design rather than decorate it.

1. **Either the hostname is in the pool key, or the address is not.** Mint takes the dialled
   address and the verification identity separately, so `conn_opts[:hostname]` does reach SNI,
   the certificate match function and the `Host` header, and setting
   `:server_name_indication` or `:customize_hostname_check` by hand would defeat it, since Mint
   derives both from `:hostname` (`deps/mint/lib/mint/core/transport/ssl.ex:450-457`, `:466`).
   But `conn_opts` are per-pool and the pool key is `{scheme, host, port, tag}`, so putting the
   IP in the host makes every hostname resolving to that address share one pool and inherit
   whichever identity opened it first. The four EVM hosts in decision 7, plus Optimism's final
   host and `robinhoodchain`, all resolve to the same three Cloudflare addresses, so that is
   the normal case here rather than an edge.
2. **A pinned dial cannot pass a bare IPv6 literal through a URL.** `URI.parse/1` strips the
   brackets, Finch passes the host string through untouched
   (`deps/finch/lib/finch/request.ex:133-158`, `deps/finch/lib/finch/uri.ex:4`), and Mint's SSL
   transport charlist-converts it and calls `:ssl.connect/4` with `inet6?` defaulting to false
   (`deps/mint/lib/mint/core/transport/ssl.ex:322-347`). `:gen_tcp.connect(~c"::1", ...)`
   returns `{:error, :nxdomain}` where the tuple form returns `{:error, :econnrefused}`. An
   `:inet.ip_address()` tuple carries its own family and is accepted whenever `:hostname` is
   given (`deps/mint/lib/mint/core/util.ex:7-18`).
3. **Req refuses the pinned combination outright.** `Req.Finch.finch_name_options/1` raises
   `ArgumentError, "cannot set both :finch and :connect_options"`
   (`deps/req/lib/req/finch.ex:546-548`), and when `:finch` names an instance the computed pool
   options, `conn_opts[:hostname]` included, are discarded (`:577-585`). Without a name, Req
   hashes the pool option set into a module name and starts a Finch under
   `Req.FinchSupervisor` that is never reaped (`:587-597`, `:605-613`). No Req shape both owns
   the instance and pins.
4. **A halt is not an error.** `{:halt, acc}` does real teardown (`Mint.HTTP.close/1` on HTTP/1,
   `deps/finch/lib/finch/http1/conn.ex:366-368`, `:390-392`, `:412-414`;
   `cancel_async_request/1` on HTTP/2, `deps/finch/lib/finch/http2/pool.ex:156-160`) but
   returns `{:ok, acc}`, so truncation has to be signalled inside the accumulator or it is
   indistinguishable from success. The connection and pool slot are not leaked, at least:
   `handle_checkin/4` removes a closed connection (`deps/finch/lib/finch/http1/pool.ex:222-232`).
5. **A decrementing per-`recv` budget is the only bound that covers the header phase.** That is
   what `:request_timeout` is on HTTP/1: decremented by each `recv` and re-checked before the
   next (`deps/finch/lib/finch/http1/conn.ex:298-301`, `:313-323`), read from the request
   options on the streaming path too (`deps/finch/lib/finch/http1/pool.ex:43-45`). "Best
   effort" (`deps/finch/lib/finch.ex:864-867`) means the overshoot is one chunk timeout, not
   that the bound is unreliable. A deadline checked inside a stream callback cannot cover the
   header section at all, because with the default `stream_headers: false` no callback runs
   until that section is parsed (`deps/mint/lib/mint/http1.ex:159-162`) and the only bound
   there is the 256 KiB `:max_header_list_size` (`:154-157`).
6. **HTTP/2 streaming has no back-pressure** (`deps/finch/lib/finch.ex:664-672`), so a hard byte
   cap wants `protocols: [:http1]`, which is also the Req/Finch default
   (`deps/req/lib/req/finch.ex:2`) and is what makes finding 5 apply at all.

Two smaller ones: `Finch.stream_while/5` does not validate its option names, unlike `request/3`
(`deps/finch/lib/finch.ex:879`), so a misspelled timeout is silently dropped and the default
applies; and Req's `remove_credentials_if_untrusted/3` (`deps/req/lib/req/steps.ex:1562-1573`)
strips only the `authorization` header and `:auth` option, comparing host, scheme and port, so
it would not strip a cookie or an `x-api-key`. `redirect: false` is the load-bearing control,
not that step.

### Gap 4: the upstream surface, measured rather than assumed

Probed 2026-09-13 with `User-Agent: raxol_web3/0.1.0 (+https://raxol.io)`:

| Target | Result |
| ------ | ------ |
| `eth`, `base`, `polygon`, `arbitrum` `.blockscout.com/api/v2/stats` | 200 JSON |
| `optimism.blockscout.com` | 301 to `explorer.optimism.io`, which returns 200 |
| `robinhoodchain.blockscout.com` (chain 4663) | **403 HTML for the honest UA, a browser UA, and no UA alike**, carrying `cf-mitigated: challenge`; `/` on the same host returns 200 |
| `eth.blockscout.com/api-docs`, `/swagger.json` | 404, though the vendor docs advertise `/api-docs` per instance |
| 12 `/api/v2/*` endpoints on `eth` | 200 with the shapes decision 7 maps |
| `api.etherscan.io/v2/api?chainid=1&module=stats&action=ethsupply` | `{"status":"0","message":"NOTOK","result":"Missing/Invalid API Key"}` |

Three consequences that are not obvious without the probe:

- **Chain 4663's API paths are challenge-gated, not absent.** The 403 is not a User-Agent check,
  since an empty and a browser UA are refused identically, and the response names the
  mechanism: `cf-mitigated: challenge`, `server: cloudflare`. The instance is serving, `/`
  returns 200, and the chain registry still lists it
  (`chains.blockscout.com/api/chains/4663` returns
  `"explorers":[{"url":"https://robinhoodchain.blockscout.com/","hostedBy":"blockscout"}]`).
  ADR-0033 records that Etherscan does not index 4663, so with the explorer API gated, 4663 is
  raw-RPC-only today. That is a dated WAF state, not a structural fact about the chain, and
  decision 7 records it as health rather than as absence.
- **Optimism's final host is not its Blockscout subdomain.** Because §7 refuses redirects, the
  chain-to-host table must carry final hosts or Optimism simply fails.
- **The Etherscan fallback is key-gated.** Even the cheapest call needs a key, so a
  zero-configuration install falls back to raw RPC rather than to Etherscan. Its free tier is
  3 calls/second and 100,000/day (`docs.etherscan.io/rate-limits`, read 2026-09-13).

And four shape findings that drive decisions 4, 7 and 8:

- `next_page_params` **key sets differ per endpoint**: address transactions returns seven keys
  (`block_number`, `fee`, `hash`, `index`, `inserted_at`, `items_count`, `value`),
  `addresses/{hash}/tokens` returns four (`id`, `value`, `fiat_value`, `items_count`), `blocks`
  returns two, `token-transfers` returns two.
- `/api/v2/addresses/{hash}/token-balances` is **unpaginated and scales with holdings**:
  254,892 bytes in 1.5 s for a widely held token contract, and **3,289,596 bytes carrying 8,009
  items in 19.8 s** for a high-token-count wallet, both HTTP 200. Reading this endpoint as a
  hang was that response arriving slowly. No fixed byte ceiling bounds it, which is why
  decision 7 does not call it.
- `/api/v2/addresses/{hash}/tokens` answers the same question **paginated**: 50 items, 26,160
  bytes, 2.4 s, four-key cursor. It is what `token_balances/2` maps onto.
- `/api/v2/stats` carries **no finalized height**. Its whole key set is `average_block_time`,
  `coin_image`, `coin_price`, `coin_price_change_percentage`, `gas_price_updated_at`,
  `gas_prices`, `gas_prices_update_in`, `gas_used_today`, `market_cap`,
  `network_utilization_percentage`, `secondary_coin_image`, `secondary_coin_price`,
  `static_gas_price`, `total_addresses`, `total_blocks`, `total_gas_used`, `total_transactions`,
  `transactions_today`, `tvl`. So `total_blocks` is a count rather than a height, and
  `average_block_time` is milliseconds.
- `/api/v2/main-page/indexing-status` is the REST route that reports indexer lag:
  `finished_indexing`, `finished_indexing_blocks`, `indexed_blocks_ratio`,
  `indexed_internal_transactions_ratio`. It is not finality, and decision 7 uses it to say how
  far behind the REST view is rather than to answer a height.

## Decision

### 1. Lift the guard into `Raxol.Core.Outbound`, and migrate its current caller

The reject set and the resolution step need `:inet` and nothing else, so they belong in
`raxol_core`, which every package already depends on and which has no HTTP dependency.

```elixir
@spec vet(String.t(), keyword()) ::
        {:ok, %{uri: URI.t(), addresses: [:inet.ip_address()], hostname: String.t()}}
        | {:error, term()}
```

Every element of `addresses` has passed the reject set, and that list is what the caller MUST
dial: returning it is what makes rule 3 enforceable rather than aspirational. It is a list
rather than a single address because `resolve/1` already returns every A and AAAA record
(`fetch.ex:271-288`), and handing a hostname to Req lets `gen_tcp` try each of them in turn, so
collapsing to one address would trade the rebinding fix for the loss of multi-address failover.
The hosts in decision 7's table are three addresses deep. A caller tries them in order, each
pinned; the all-must-pass rule in `check_host/1` (`fetch.ex:256-266`) is what makes iterating
the list safe, since a list with one bad member is never returned at all.

`blocked?/1`'s clause table moves verbatim. It is the most carefully built part of the existing
guard, its IPv4-in-IPv6 coverage is exactly the part a reimplementation gets wrong, and
`fetch.ex`'s own tests already pin it.

`:schemes` defaults to `[:https]`, and `Actions.Fetch` passes `[:http, :https]` to keep its
documented behaviour. That is the single intentional difference between the two callers:
silently making the fetch tool https-only would be an unrelated behaviour regression shipped
under a web3 change.

`Actions.Fetch` migrates to `Outbound`, and `check_url/1`, `check_host/1`, `resolve/1`,
`getaddrs/2` and `blocked?/1` are **deleted** from `fetch.ex`. A second copy of an SSRF reject
set is the failure mode this decision exists to prevent. `check_hop/2` (`fetch.ex:246-254`)
stays where it is: it is the redirect follower's audit vocabulary (`{:blocked_redirect, host}`
distinguishing a blocked origin from a host that tried to walk somewhere private), not outbound
policy, and the web3 client refuses 3xx outright, so lifting it would put a concept into
`raxol_core` with exactly one caller forever.

`Actions.WebSearch` has nothing to migrate, which is worth stating so that nobody adds a check
to it later believing this decision asked for one. Its own moduledoc explains why
(`web_search.ex:27-33`): the destination is a fixed vendor endpoint from `@providers` and the
model controls only the query string, so there is no attacker-chosen address to guard, and a
DNS check would only make that action's tests depend on a resolver. It reaches the network
through `Fetch.transport/1` and `Fetch.collect/3`, both of which are untouched here.

This lift does **not** close rule 3 for `Actions.Fetch`, and the earlier draft of this ADR
claimed it did. That tool keeps `req_transport/2`, which requests a URL carrying the hostname
(`fetch.ex:652-667`), so it resolves twice exactly as before. The residual limit its moduledoc
states (`fetch.ex:44-51`) stays true and stays in the moduledoc, verbatim, rather than being
deleted by a refactor that did not earn it. Closing it there needs a pinned dial that also
speaks `http` and lives in `raxol_agent`; that is listed under what this ADR does not decide.
What `Fetch` gains here is one reject set instead of two, not a rule it did not have.

### 2. `Raxol.Web3.HTTP` is the only module in the package permitted to open a socket

One module, one pipeline, and one connection per request, opened with `Mint.HTTP.connect/4`
directly rather than through a pool: decision 3 sets out why a pool is the problem here rather
than the saving. Req is not on this path at all, since it raises on `:finch` plus
`:connect_options` (`deps/req/lib/req/finch.ex:546-548`) and its auto-spawned hashed instances
are never used, per gap 3 finding 3. The JSON-RPC POSTs this package absorbs from
`ChainReader.JSONRPC` go through here too, which is how that client's absent timeout
(`jsonrpc.ex:99-112`) and its raw-upstream-body error tuple (`:119-120`) stop existing rather
than moving down a layer unchanged.

The pipeline is fixed and ordered, so that the expensive and the dangerous steps cannot be
reordered by a backend author:

```
vet (Outbound) -> token bucket -> circuit breaker -> pinned dial -> bounded read -> redact
```

A backend that builds its own HTTP call is a defect, not a style difference. This is
ADR-0033 §7's "one guarded client", stated as a package invariant with one enforcement site.

The error taxonomy is closed, and deliberately carries no upstream text. Every variant that
would otherwise name a host carries an opaque origin id instead, because the host is itself the
secret when an endpoint is a per-account URL, and the id-to-origin map stays in process state:

```elixir
{:blocked, reason} | {:dns_failed, origin_id} | {:rate_limited, retry_after_ms}
| {:breaker_open, origin_id} | {:http, status}
| {:upstream_refused, :auth | :rate_limit | :not_found | :unknown}
| {:too_large, limit} | {:timeout, :connect | :chunk | :deadline}
| {:transport, atom()}
```

`{:upstream_refused, _}` exists because the measured failure is not always an HTTP status.
Etherscan V2 answers an unauthenticated call with HTTP 200 and
`{"status":"0","message":"NOTOK","result":"Missing/Invalid API Key"}`, which `{:http, 200}`
cannot express and which must not be expressed by relaying the upstream's own words. The
mapping from a recognised body shape onto one of those four atoms is ours, declared per
backend, so nothing written upstream crosses the boundary.

The taxonomy is one package's, but not one module's, and the split is worth stating because it
is where a reviewer will look for a leak. `Raxol.Web3.HTTP` never inspects a status or a body,
so it produces the transport half: `{:blocked, _}`, `{:dns_failed, _}`, `{:rate_limited, _}`,
`{:breaker_open, _}`, `{:too_large, _}`, `{:timeout, _}` and `{:transport, _}`. Any status comes
back as a response, because decision 9 needs the challenge body to arrive intact for the router
to classify it, and because whether a 404 is an answer depends on the endpoint. The backend
layer decides the rest: `{:http, status}`, `{:upstream_refused, _}`, and two variants that
implementation added because they had nowhere else to live. `{:decode_failed, atom()}` names a
body that is not what its content type claimed, and `{:unsupported, callback}` names an
optional callback a handle declines. Neither carries upstream text.

### 3. Pin the vetted address, and let the hostname carry identity

`Mint.HTTP.connect(:https, address, 443, hostname: host, protocols: [:http1], ...)`, where
`address` is an `:inet.ip_address()` tuple from `Outbound.vet/2` and `host` is the vetted name.
Mint takes the two separately: the tuple is dialled, and the name reaches SNI, the certificate
match function and the `Host` header, all derived from that one `:hostname` option
(`deps/mint/lib/mint/core/util.ex:7-18`;
`deps/mint/lib/mint/core/transport/ssl.ex:315-330`, `:459-501`, `:561-573`;
`deps/mint/lib/mint/http1.ex:170-178`, `:244`, `:1265-1278`). `:server_name_indication` and
`:customize_hostname_check` are never set by hand.

This is the first implementation of §7 rule 3 in the repository.

Dialling Mint directly, one connection per request, is the decision rather than an
implementation detail, because a pool is keyed by the URL host while the identity is per-pool.
Three separate failures follow from keying a pool by the vetted address:

- **Cross-host connection reuse.** The key is `{scheme, host, port, tag}`
  (`deps/finch/lib/finch/pool.ex:143`), so every hostname resolving to a shared address shares
  one pool and inherits whichever identity opened it first. Measured on 2026-09-13, `eth`,
  `base`, `polygon`, `arbitrum` and `robinhoodchain` on `.blockscout.com`, plus
  `explorer.optimism.io` through its CNAME, all resolve to
  `{104.26.1.65, 104.26.0.65, 172.67.72.116}`. A Base query issued after an Ethereum query
  would go out with `Host: eth.blockscout.com` over a session whose SNI said the same, so it
  returns Ethereum data under a Base chain reference, or a 421, silently either way. That is
  the whole chain table, not an edge case.
- **No IPv6 path.** A pool is keyed by a host string, `URI.parse/1` strips the brackets from an
  IPv6 literal, and `:ssl.connect/4` then resolves that string with family `inet` unless
  `inet6: true` is set per pool (gap 3 finding 2). A tuple carries its own family.
- **A lazy default pool.** `Finch.Pool.Manager.get_pool/3` defaults to `start_pool?: true` and
  starts a pool from the instance configuration whenever the key is absent
  (`deps/finch/lib/finch/pool/manager.ex:96-106`, `:132-134`), so a first request, a restart, or
  a race between two concurrent first requests can dispatch through a pool that was never given
  `:hostname`. That fails closed on the certificate, which is the right direction and the wrong
  diagnostic.

Dialling directly also deletes the cost an earlier draft accepted. There is no pool key, so a
rotating DNS answer creates nothing to bound and no per-origin address cache is needed. Not
caching the vetted address is the stronger position anyway: `:inet.getaddrs/2` hits the OS
resolver cache, so re-vetting per request is a local lookup, while a cache is precisely the
thing that would let a rotated answer skip the reject set, which is rule 2. The price is one
TLS handshake per request. That is affordable against a 3-calls-per-second upstream budget
behind decision 5's response cache, and it is the price `ChainReader.JSONRPC` already pays
through Req today without a pooling benefit it can name.

### 4. Bound size and time in the client, because nothing below does

The response is read in a `Mint.HTTP.recv/3` loop that owns four bounds, none of which any
layer below supplies:

- **Size.** A byte counter over the accumulated body, aborting at the ceiling. The default is
  2 MiB, matching `Fetch`'s `@max_max_bytes`, configurable per backend. It is sized against the
  endpoints decision 7 actually calls, all of which paginate: the largest measured page is 50
  items at roughly 26 KB, so the ceiling is around eighty times a normal response. It is
  deliberately **not** sized against `/api/v2/addresses/{hash}/token-balances`, which is
  unpaginated, returned 3.1 MB for a single wallet, and which decision 7 therefore does not
  call. An unpaginated list has no safe ceiling; the answer is a different endpoint, not a
  bigger number.
- **Content-length.** Where the header is present and exceeds the ceiling, the response is
  refused before a body byte is read.
- **A wall-clock deadline.** Computed once per request and re-checked before every `recv`, with
  each `recv` given `min(remaining_deadline, chunk_timeout)`. This is the shape Finch implements
  for `:request_timeout` (`deps/finch/lib/finch/http1/conn.ex:298-301`, `:313-323`), and owning
  the loop is what makes it cover the header phase: a deadline checked inside a stream callback
  never fires while headers are arriving, because no callback runs until that section is parsed
  (gap 3 finding 5). Overshoot is bounded by one chunk timeout.
- **Per-`recv` silence.** The chunk timeout bounds a connection that stops talking.

Defaults: connect 5 s, chunk 10 s, deadline 20 s. The worst case is the sum of the connect
timeout, the deadline and one chunk timeout, and it is stated rather than assumed.

Truncation is never a success. The accumulator is a tagged state that starts `:incomplete` and
is promoted to `:complete` only on the terminating response; a ceiling, a content-length
refusal or an expired deadline sets a terminal `{:too_large, _}` or `{:timeout, :deadline}` tag
instead. That matters beyond this loop, because the hazard exists in any halt-based reader:
`Finch.stream_while/5` returns `{:ok, acc}` for both a complete response and a halt (gap 3
finding 4), so a halt taken at the status or header entry yields an accumulator with no body
and no status. An accumulator whose initial value looks like a success then turns a refused
oversized response into an empty 200, which for `list_transactions/3` is indistinguishable from
an address with no transactions. The tag is what makes that unrepresentable.

### 5. Rate limiting, health, and caching reuse the existing primitives, keyed per origin

All three are ETS-backed, and **one supervised process in this package creates all three tables
and hands their references out**. That is not a detail. `:ets.new/2` tables are owned by the
process that creates them (`Raxol.Core.TokenBucket.new/1`, `token_bucket.ex:63-65`;
`Raxol.MCP.CircuitBreaker.new/1`, `circuit_breaker.ex:31-33`), and the one existing caller
creates its tables in a GenServer `init_manager`
(`packages/raxol_mcp/lib/raxol/mcp/registry.ex:264-278`). There is no such thing as a public
ETS table with no owning process, and letting callers create them has three distinct failure
modes: a bucket created by a short-lived process resets to full capacity, so the upstream budget
is spent once per process; a breaker created per caller never observes anyone else's failures;
and a lookup against a dead table raises `ArgumentError` inside whoever still holds the
reference, which is a crash rather than an error tuple. `Raxol.Web3.Supervisor` owns them.

- `Raxol.Core.TokenBucket`, keyed per origin, `capacity` and `refill_per_second` passed per
  call. Etherscan is seeded at the measured 3 calls/second; Blockscout publishes no figure, so
  it gets a conservative default plus configuration. A refusal becomes
  `{:rate_limited, retry_after/3}` rather than a sleep inside the client. The bucket is
  node-local, so a fleet of N nodes spends N times the upstream budget, which ADR-0033 §1
  records and leaves open; since the free tier is the binding product constraint, the scope is
  restated here rather than left one ADR away.
- `Raxol.MCP.CircuitBreaker`, whose `key()` widens by one variant to `{:origin, String.t()}`
  (`circuit_breaker.ex:24`). That is precisely the additive change ADR-0033 decision 6
  anticipated. A 403 challenge page and a 429 storm are both `record_failure/3`, so the router
  fails over instead of hammering.
- `Raxol.Web3.Cache` per ADR-0033 decision 6. The key is `{origin_id, endpoint,
  canonical_params}`, where `canonical_params` is built by allowlist from the parameters the
  endpoint declares and never from the request URI, so a key-bearing query parameter cannot be
  folded into a cache key by accident: ADR-0033 §7 names cache keys as one of the four places a
  credential leaks in practice. TTL is chosen by endpoint class, chain stats in seconds and a
  finalized transaction effectively immutable. The height-bearing routes are the constrained
  case and are settled with decision 7 rather than deferred, because a cached height composed
  with a live one is exactly what breaks `block_height/1`.

### 6. Redaction is a module, and upstream bodies never reach an error term

`Raxol.Web3.Redact.reason/1`, modeled on `Raxol.Telegram.HTTP.redact_transport_reason/1`
(`telegram/http.ex:139-142`), the one existing pattern that already does this correctly: a
transport error collapses to its atom, a struct to its module, anything else to a generic
atom.

Four rules. No upstream response body in an error term, which is what `{:upstream_refused, _}`
in decision 2 exists to make possible. No URL carrying a query string in a log line or error
term. A key-bearing query parameter stripped before a URI is rendered anywhere. And no
caller-influenced host in an error term, which is why decision 2's variants carry an origin id.
These are measured rather than theoretical: Etherscan returns `"Missing/Invalid API Key"` inside
a 200 body, and ADR-0033 §7 records upstreams echoing the failing URL with its query string.

One part of the §7 rule cannot be kept by a module of ours, and saying so beats restating it.
Finch builds its telemetry metadata from the whole `Finch.Request`, headers and query string
included, and emits it from inside the library before any code of ours runs
(`deps/finch/lib/finch/http1/conn.ex:111`, `deps/finch/lib/finch/http1/pool.ex:47`). Mint emits
nothing comparable, which is a second reason decision 3 dials it directly, but any handler
attached to `[:finch, _, _]` elsewhere in the node still sees whatever Req-based caller remains
outside this package. So ADR-0033 §7's "never reaches a telemetry measurement" is read here as:
no telemetry this package emits carries a credential, credentials travel in headers rather than
query strings wherever the upstream permits it, and a credential-holding node must not attach an
unscrubbed handler to `[:finch, _, _]`.

### 7. The EVM REST backend maps endpoints to callbacks, and declares what REST cannot answer

`Raxol.Web3.Backend.Blockscout`, against `/api/v2/*`. Every path below returned 200 on
2026-09-13.

| Callback | Path | Note |
| -------- | ---- | ---- |
| `chain_info/1` | `/api/v2/stats` | 19 keys, none of them a height and none of them finality |
| `block_height/1` | **RPC only**, plus `/api/v2/main-page/indexing-status` for lag | both numbers from one source; returns a map, not a three-tuple, because the lag has nowhere else to go |
| `get_transaction/2` | `/api/v2/transactions/{hash}` | |
| `account_info/2` | `/api/v2/addresses/{hash}` | carries `ens_domain_name` |
| `list_transactions/3` | `/api/v2/addresses/{hash}/transactions` | 7-key cursor |
| `token_balances/2` | `/api/v2/addresses/{hash}/tokens` | paginated, four-key cursor. **Not** `/token-balances`, which is unpaginated and returned 3.1 MB for one wallet |
| `list_token_transfers/3` | `/api/v2/addresses/{hash}/token-transfers` | |
| `get_logs/2` | `/api/v2/addresses/{hash}/logs` | |
| `contract_metadata/2` | `/api/v2/smart-contracts/{hash}` | |
| `list_nfts/2` | `/api/v2/addresses/{hash}/nft` | |
| `resolve_name/2` | `/api/v2/search?q=` | |
| `get_block/2` | `/api/v2/blocks/{number}` | |
| `read_contract/2` | **not REST**; `eth_call` through the RPC reader | the path any balance gate must take |
| `raw_request/2` | **not offered** | see below |

Two structural points.

`raw_request/2` is not implemented by this backend, and its read allowlist is therefore empty.
ADR-0033 §3 introduced the allowlist because "an unbounded passthrough to a JSON-RPC backend
reaches `eth_sendRawTransaction`". A REST backend has no method parameter to abuse, so
declining the callback keeps §4's "read-only by construction" claim structural rather than
policed.

`block_height/1` takes both numbers from the RPC reader, `latest` and `finalized`, and uses REST
only to report how far behind the indexer is. ADR-0033 made the finalized split first-class
precisely because a bare integer "silently lies on two of our four target families", and
Blockscout REST exposes no finality, so the obvious shape was a REST height composed with an RPC
finality. That shape is wrong. The two numbers would come from different systems, the REST one
is an indexer view and is cacheable, and an indexer that is behind (or a cached page) yields a
`finalized_height` above `height`, which is the one invariant the tuple exists to express: a
consumer using the pair for confirmation depth reads a negative depth. So the heights are
same-source, and the lag the composed version would have hidden is reported instead, from
`/api/v2/main-page/indexing-status`. That also takes REST off the hot path of the callback most
likely to be polled.

Chain-to-host table, final hosts only, because redirects are refused:

| Chain | Host | Status |
| ----- | ---- | ------ |
| 1, 8453, 137, 42161 | `{eth,base,polygon,arbitrum}.blockscout.com` | serving |
| 10 | `explorer.optimism.io` | serving, reached directly rather than via the 301 |
| 4663 | `robinhoodchain.blockscout.com` | `challenge_gated` (`cf-mitigated: challenge`, 2026-09-13); raw RPC only until it lifts |

### 8. Cursors are opaque, authenticated, and key-constrained

A cursor is a versioned, Base64url-encoded encoding of the upstream `next_page_params` map, with
the origin and endpoint bound into it so it cannot be replayed against a different endpoint or
chain, and **carrying a MAC over the whole payload under a per-node key**. A cursor whose MAC
does not verify is refused before anything is decoded. `items_count` and any offset-like field
are never exposed.

The MAC is not belt and braces. Base64url is an encoding, not integrity protection, and the
decoded map's keys become upstream query parameters, so without it anyone who can hand a cursor
back can add or rewrite keys and inject attacker-chosen parameters into our next upstream
request: from our address, under our rate-limit budget, with our key attached where one is
configured. On an MCP-served surface the cursor is model-visible and model-settable, so
untrusted upstream text reaches the outbound query string through a value the model copies
forward.

Verification is necessary and not sufficient. The decoded keys are additionally allowlisted per
endpoint against the observed key set and type-coerced, so even an authentic cursor cannot
introduce a parameter the endpoint does not take. That is data, a key list per endpoint, not a
struct per endpoint, so it does not reintroduce the coupling ADR-0033 §3 refused when it
required an opaque cursor in both directions. The measured divergence remains the argument for
opacity: seven keys on address transactions, four on `tokens`, two on `blocks`.

### 9. Identify honestly, and treat a refusal as a health signal

`User-Agent: raxol_web3/<version> (+https://raxol.io)`, per ADR-0033 §7. The probe supports the
posture empirically rather than only ethically: four instances accept the honest UA, and the
one that refuses it refuses a browser UA and an absent UA identically, so there is nothing to
buy by lying. A 403 with an HTML body is `record_failure/3` plus router failover, never a
User-Agent retry.

The header has to be set explicitly, and that is worth stating because the
default is not silence. Mint puts `user-agent: mint/<version>` on every request that does not
carry one (`deps/mint/lib/mint/http1.ex:1265-1269`), so a request built without this header
identifies the HTTP library rather than us: honest in the trivial sense and useless to an
upstream deciding whether to serve us. Observed on the wire while implementing decision 4.

### 10. Dependencies

`raxol_web3` declares `{:mint, "~> 1.8"}` and `{:castore, "~> 1.0"}`, and does **not** declare
`req` or `finch`. Decision 3 dials Mint directly and decision 2 routes every outbound call in
this package through that one path, so there is no caller for Req here and no owned Finch
instance to name. Mint is declared rather than inherited: neither `:finch` nor `:mint` is
declared anywhere in the repo today and both arrive transitively through `req`, so building on
an undeclared transitive dependency would be a version trap. `:castore` follows the `raxol_cli`
precedent (`packages/raxol_cli/mix.exs:173-182`): it is an optional dependency of Mint, and
Mint's `add_cacerts/1` falls back to `CAStore.file_path()` only when
`:public_key.cacerts_get()` raises (`deps/mint/lib/mint/core/transport/ssl.ex:585-597`), so a
packaged binary without it fails on the first HTTPS connect.

These are hard dependencies of `raxol_web3` only. ADR-0033 decision 2 keeps them out of
`raxol_mcp` and therefore out of every raxol install, and dropping `req` from this package's
tree leaves the repo with one fewer HTTP client rather than one more.

## Consequences

### Positive

- §7 rule 3 becomes real for the first time, in one module, against a vetted address list.
- One enforcement site for scheme, address, pinning, redirect, size, deadline and redaction, so
  a new backend cannot regress any of them by omission.
- The reject set stops being private to one agent tool, which is the scope gap
  `Raxol.Docs.ProseLint`'s moduledoc describes for prose and which applies just as well here.
- `ChainReader.JSONRPC`'s absent timeout (`jsonrpc.ex:99-112`) and its raw-upstream-body error
  tuple (`:119-120`) are fixed by moving it onto this client, rather than recorded as adjacent,
  which is ADR-0033's gap 3 closing for real.
- Chain 4663's real status, a managed challenge on the API paths, is recorded with its evidence
  and carried as health rather than as absence.

### Negative

- One TLS handshake per request, because there is no connection pool. Bounded by the response
  cache and by upstream rate limits that sit far below any plausible handshake cost.
- Owning the `recv` loop means owning the four bounds in decision 4, including the deadline
  arithmetic that `:request_timeout` would otherwise have done inside Finch.
- `Actions.Fetch` is refactored for a reason external to it, which puts an agent-surface change
  in a web3 changeset. The `:schemes` default is the mitigation, and the tool keeps its
  documented rebinding limit rather than silently inheriting a fix it does not get.
- The EVM backend is only as good as a vendor endpoint set with no published spec: `/api-docs`
  is 404, so the mapping in decision 7 is probe-derived and needs re-probing on upgrade.
- Cursor MACs mean cursors do not survive a key rotation, so a paging caller gets one refusal
  and has to restart the page walk.

### Mitigation

- The rebinding property test is written against `Outbound` plus the pinned dial together,
  since neither half alone proves rule 3.
- `Fetch`'s existing guard tests migrate with the code and gate the lift, so the refactor is
  proven by tests that predate it.
- The chain-to-host table and 4663's `challenge_gated` status are data with a dated comment,
  re-probed by `scripts/probe_web3_upstreams.sh`, which prints a dated table and is allowed to
  be skipped offline but not silently wrong.
- Every upstream figure that is a guess rather than a measurement is labelled as such in
  configuration, following ADR-0033's practice of recording what remains unverified.

### What this ADR does not decide

- Whether we self-host a Blockscout instance for chain 4663, which is the other way that chain
  regains an explorer surface if the challenge does not lift.
- Whether `Actions.Fetch` eventually gets a pinned dial of its own. It would need an `http`
  variant and a home in `raxol_agent`; until then that tool's documented double-resolve stands.
- Per-endpoint cache TTL values, except for the height-bearing routes, which decisions 5 and 7
  settle together because a cached height is what breaks the monotonicity of `block_height/1`.
- The Tron, Solana, Canton and Aztec backends, which ADR-0033 sequences separately and which
  are the reason its backend contract has optional callbacks at all.
- Whether `Raxol.Core.Outbound` also absorbs the uncapped CLI download at
  `packages/raxol_cli/lib/raxol/cli/update.ex:491-497`, and the unredacted `post/3` sibling at
  `packages/raxol_telegram/lib/raxol/telegram/http.ex:52-59`. Both are real and both are
  adjacent; neither is in this scope.
- Whether `capabilities/1` itself is computed from live backend health. Implementation
  answered the operator-facing half without changing the callback: `Raxol.Web3.Router`'s
  `coverage/2` reports which callbacks have a source that both declares them and is not
  open-breakered, so the degradation is legible at the moment it happens. `capabilities/1`
  stays a static declaration, because a backend cannot honestly report health it has not
  measured, and the router is the only thing holding both the declaration and the verdict.
- **Whether a source that cannot answer the six required callbacks may be a backend.** This is
  the load-bearing one, and building the router is what surfaced it. No `eth_*` method answers
  "the transactions of this address" or "the tokens this address holds", so the raw-RPC
  fallback in §5's coverage matrix cannot implement `list_transactions/3` or
  `token_balances/2`, and therefore cannot be a `Raxol.Web3.Backend` as ADR-0033 §3 defines
  one. The consequence is concrete: chain 4663, whose only explorer surface is
  challenge-gated, has nothing for the router to fail over TO, and the same holds for any
  chain served only by a node. Either the required set shrinks or a partial source gets a
  contract of its own, and that is an ADR-0033 question rather than a module's to settle.
  Implementing it either way would have meant a `list_transactions/3` that returns
  `{:error, {:unsupported, _}}`, which is a stub with a behaviour attached.
- Publication of `raxol_web3` to Hex, left open by ADR-0033.

## Alternatives considered

### Keep using Req end to end, with `connect_options[:hostname]`

Rejected on two mechanisms found in the vendored source. Req raises
`ArgumentError, "cannot set both :finch and :connect_options"`
(`deps/req/lib/req/finch.ex:546-548`), so a pinned request cannot ride an owned instance at
all; and without a named instance Req hashes the pool option set into a module name and starts
a Finch under `Req.FinchSupervisor` that is never reaped (`:587-597`, `:605-613`), so pinning
per origin would leak a supervisor child per upstream. Req remains fine elsewhere in the repo
for targets that are neither pinned nor size-capped.

### Keep Finch, and key the pool by hostname

The tag is part of the pool key (`deps/finch/lib/finch/pool.ex:143`) and is settable per request
(`deps/finch/lib/finch/request.ex:113-115`), so `{:https, ip, 443, hostname}` fixes the
cross-host reuse in decision 3 without leaving Finch. Rejected because it fixes one of that
decision's three failures and leaves two. A v6 pool still needs
`conn_opts: [transport_opts: [inet6: true]]` and a v4 pool must not have it, which makes address
family a pool configuration dimension; and an absent pool still silently inherits the instance
default (`deps/finch/lib/finch/pool/manager.ex:96-106`), so every request would additionally
have to assert its own pool exists with `Finch.find_pool/2` and refuse rather than dispatch.
Three guards to keep a pool whose benefit is one saved handshake against a 3-per-second upstream
is the wrong trade. Recorded because it is the right answer for anyone who needs pooling here
later.

### Skip pinning and accept the double resolve

Rejected. It is §7 rule 3, ADR-0033's mitigation list names the exact test it requires, and
`fetch.ex`'s own moduledoc already identifies the hole. Declining it would mean writing a new
guarded client whose headline guarantee is the one guarantee it does not provide.

### Make Etherscan V2 the primary EVM source

Rejected on measurement: it requires a key for even the cheapest call, and its free tier is 3
calls/second. It stays the configured fallback where a key exists, which is what ADR-0033's
coverage matrix already says.

### Blockscout PRO, or proxying the hosted Blockscout MCP

Rejected on ADR-0033's findings, which this ADR does not relitigate: the licence is revocable
and forbids redistribution, the hosted MCP server has a ten-call free session budget, and it
requires a PRO key from 2026-10-08.

### Reuse `Actions.Fetch` from `raxol_web3`

Rejected on graph position. It lives in `raxol_agent`, which depends on main `raxol`, while
ADR-0033 decision 2 places `raxol_web3` below `raxol_payments`. Lifting the guard down into
`raxol_core` is the same work without the cycle.

## Validation

### Probes, re-runnable with the honest User-Agent

`scripts/probe_web3_upstreams.sh` prints a dated table, and is the artifact these claims are
re-verified from, because six of them need more than one `curl`: the shared address set, the
challenge header on 4663, the 3.1 MB `token-balances` response, the paginated `tokens`
alternative, the per-endpoint cursor key sets, and the absence of any finality field. The
minimum by hand:

```
UA='raxol_web3/0.1.0 (+https://raxol.io)'
curl -sA "$UA" https://eth.blockscout.com/api/v2/stats | jq -r 'keys|join(",")'
curl -sIA "$UA" https://robinhoodchain.blockscout.com/api/v2/stats | grep -i cf-mitigated
curl -sA "$UA" 'https://api.etherscan.io/v2/api?chainid=1&module=stats&action=ethsupply'
curl -sA "$UA" https://eth.blockscout.com/api/v2/main-page/indexing-status
for h in eth base polygon arbitrum robinhoodchain; do dig +short A $h.blockscout.com; done
```

Three items ADR-0033 listed as unverified are now answered, and one of its findings has changed.
These are dated claims, not permanent ones.

| ADR-0033 item | Status on 2026-09-13 |
| ------------- | -------------------- |
| "whether the Base and Polygon Blockscout 500 responses are transient, since that rests on a single sample" | Transient. Both return 200 |
| "whether the Etherscan V2 free tier allows 5 or 3 calls per second" | 3 per second, 100,000 per day; 5 per second is the paid Lite tier |
| Cloudflare "answered a non-browser User-Agent with a 403 challenge page", with a browser UA succeeding on `robinhoodchain` | No longer reproduces on that instance: honest, browser and absent UA all return 403, and the response names the mechanism (`cf-mitigated: challenge`). The other four instances accept the honest UA. All six hosts share one Cloudflare address set, which is what decision 3 turns on |

### Tests

1. **Rule 3, in two halves, because it cannot be tested in one.** A resolver that returns a
   public address on the first call and a private one on the second must not be reachable, but
   no local test can connect through the whole pipeline: a test endpoint necessarily listens on
   loopback, and the reject set refuses loopback, which is exactly the hole the guard exists to
   close. So the property is split where it lives. `Outbound.vet/2` is property-tested over IP
   literals, IPv4-mapped forms and a changing resolver, and returns only the answers it
   checked. The dial takes `:inet` address tuples and **refuses a name** rather than resolving
   one, so there is no code path between the two that could re-resolve; that refusal is tested
   directly, as is the fact that the guarded path cannot reach the dial's own test endpoint.
   Stated this way rather than as an end-to-end claim no test can make.
2. **Pinning preserves verification.** Dialling an IP tuple with `hostname:` set must present
   that hostname in SNI and verify the certificate against it; a deliberately mismatched
   `hostname:` must fail the handshake rather than connect.
3. **Two hostnames, one address.** Two vetted hosts sharing one address are each reached under
   their own name: the second request's `Host` header and SNI are its own, not the first's. This
   is the test a pool-keyed design fails, and the Blockscout set is a ready-made fixture for it.
4. **An IPv6-resolved target connects.** A host with only AAAA records is reachable, which is
   what distinguishes a tuple dial from a host-string dial that returns `:nxdomain`.
5. **Guard parity.** `Fetch`'s existing reject-set tests pass unchanged against
   `Raxol.Core.Outbound`, `Fetch` still accepts `http` while the web3 client refuses it, and
   `vet/2` returns every vetted address rather than one.
6. **Size cap.** A response exceeding the ceiling is `{:error, {:too_large, _}}`, never a
   truncated success, and the connection is torn down. A `content-length` above the ceiling is
   refused before a body byte is read. The accumulator's tag is what the assertion reads, since
   a halt-based reader reports success on abort.
7. **The deadline covers headers.** A slow-drip *header* section that never exceeds the chunk
   timeout still fails at the wall-clock deadline. A body-only version of this test passes
   against the weaker mechanism this ADR rejected, so the header case is the one that has to be
   written.
8. **Redirect refusal.** A 3xx is an error, and no request is issued to the target host.
9. **Redaction.** No test may find an upstream body, a query string, a key, or a
   caller-influenced host in any error term or log line; asserted on the error path
   specifically, which ADR-0033 §7 names as where this breaks. The 200-with-error-body path is
   included, and must surface `{:upstream_refused, :auth}` and nothing else.
10. **Cursor integrity.** A cursor with a flipped byte is refused; a cursor from one endpoint or
    chain is refused on another; a cursor whose decoded map carries a key the endpoint does not
    declare is refused even when its MAC verifies; and no `items_count` or offset appears in an
    emitted cursor.
11. **Rate limit and breaker.** A bucket refusal surfaces `retry_after` without sleeping in the
    client; repeated 403 or 429 trips the breaker and the router fails over. Both tables survive
    the death of the process that made the call, which is what naming an owner buys.
12. **`block_height/1` is monotone.** `height` and `finalized_height` both come from the RPC
    reader, so `finalized_height <= height` holds even when the REST indexing status reports
    lag; the backend reports `unit: :block` and never infers finality from REST.

## References

- ADR-0033: Indexer-agnostic web3 data surface, whose decisions 3, 5, 6 and §7 this implements,
  and whose licence findings make a REST client the only available route
- ADR-0037: Remote transport for the MCP client, the sibling capability for the upstreams that
  are MCP servers rather than REST APIs
- ADR-0012: MCP as a rendering target
- `docs/proposals/web3-upstream-survey.md`: the per-upstream verdicts and wire-level findings
- `packages/raxol_agent/lib/raxol/agent/actions/fetch.ex:44-51`: the documented rule 3 gap this
  ADR closes
- Blockscout REST API and keyset pagination: `https://docs.blockscout.com/devs/apis/rest`
- Etherscan rate limits: `https://docs.etherscan.io/rate-limits`
