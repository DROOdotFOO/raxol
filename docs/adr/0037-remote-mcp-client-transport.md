# ADR-0037: Remote transport for the MCP client

## Status

Accepted, 2026-09-13. **Implemented 2026-09-14** in `raxol_mcp` (the transport, the era probe,
the parser, the concurrency policy and the transport-side metering gate) and in `raxol_agent`
(the remote `.mcp.json` admission, the provenance rule and the spend-gate reservation). All
wire-level claims about the upstream servers below are either cited to ADR-0033's probe of
2026-08-31 or to vendor documentation read on 2026-09-13.

Four things changed under contact with the code, and each is recorded here rather than only in
a commit message because three of them would otherwise read as an implementation that ignored
its own decision:

1. **A generic HTTP 400 is not era evidence; an explicit JSON-RPC code is.**
   Measured 2026-09-14: `mcp.trongrid.io/mcp` answers a `server/discover` probe
   with HTTP 400 and a top-level code `-32601`, while `mcp.tronscan.org/mcp`
   answers 400 with a Java stack trace and no protocol code. The first response
   demotes because method-not-found is specific protocol evidence wherever the
   server carries it. The second does not persist an era verdict: 400 can also
   mean malformed input, policy or intermediary refusal, so using it alone
   would poison future connections until the TTL. Only 404, 405 and 501 demote
   by HTTP status.
2. **The probe carries what both eras require.** A 2025-06-18 server refuses a request with no
   `MCP-Protocol-Version`, with a 400, reproduced against the legacy reference server before
   the upstream measurement arrived. So the probe sends `Mcp-Method`, `Mcp-Name` and
   `MCP-Protocol-Version` together and a modern server ignores the extra header.
3. **`send/3` carries `%{method:, params:, reservation:}` rather than `iodata()`.** Decision 2
   requires `Mcp-Method` and `Mcp-Name` on every modern post, which a transport handed opaque
   bytes cannot set without re-parsing what it was just given, and decision 7's gate needs the
   tool name and the reservation from the same call. Encoding belongs to the transport, which
   already owns framing. A new `session/1` returns `{:handshake | :ready, %{version:,
   concurrency:}}`, because the client has to know whether to send `initialize` BEFORE it sends
   anything: a modern server is specified not to answer it, so a client that guessed would sit
   in `:initializing` forever.
4. **Per-request capability discovery is not implemented.** Nothing in `Raxol.MCP.Client`
   consumes capabilities, so a `server/discover` per request would double every round trip for
   data no caller reads. The probe's own discover result is what the verdict is taken from, and
   tools still come from `tools/list`.

The initialization entry has a separate finite `init_timeout`, longer than the
caller-facing `call_timeout` by default. A short request timeout must not close
a client while its subprocess is still starting, but an initialization timeout
or explicit JSON-RPC error flushes the startup queue and moves the client to
`:closed` with an `{:initialization_failed, reason}` error.

This is a **prerequisite for ADR-0033**, not an extension of it. That ADR's decision 6 lists
`Raxol.MCP.Client` under "what is reused" and routes Tron through TronGrid MCP and Canton
through ccscan MCP, and its decision 2 makes `raxol_mcp` a *required* dependency of
`raxol_web3` specifically because "two of the chains that motivate this ADR are served
primarily by upstream MCP servers". Both of those servers are hosted HTTP endpoints.
`Raxol.MCP.Client` can only spawn a local subprocess, so the primary Tron path and the only
Canton path are unreachable by the client the ADR plans to reuse. This decision closes that
hole once, for every hosted upstream.

Also occasioned by a concrete hosted server we intend to consume: a commercial intelligence
API whose MCP surface is a per-account URL with bearer auth, serving a fixed tool set plus
tools that are discovered at connect time and billed per call. It is described below only by
the wire behaviour its public documentation states. Nothing vendor-specific is decided here,
and no integration is committed by this ADR.

## Context

### Gap 1: the transport is four inlined assumptions, not a seam

`Raxol.MCP.Client` is a JSON-RPC session machine welded to one transport:

| Concern | Where | What it assumes |
| ------- | ----- | --------------- |
| Config | `client.ex:138` | `Keyword.fetch!(opts, :command)`; a spec without a command cannot construct |
| Connect | `client.ex:161-186` | `Port.open({:spawn_executable, find_executable/1}, ...)` with `{:line, 1_048_576}` |
| Write | `client.ex:355-362` | `send_to_port/2` guards on `is_port(port)`; anything else silently returns `:ok` |
| Read | `client.ex:228-234` | messages arrive as `{port, {:data, {:eol | :noeol, chunk}}}`, reassembled through `state.buffer` (`client.ex:260-273`) |
| Teardown | `client.ex:236-244`, `:249-254` | `{:exit_status, code}` and `Port.close/1` |

Everything else in the module (`pending`, `next_id`, `register_pending/3`, the
`initialize` sequence at `client.ex:331-343`, `handle_result/3`, the tool cache) is
transport-independent and correct. Roughly 60 of 395 lines are the part that cannot reach a
URL.

The silent-write path deserves separate mention: `send_to_port/2` falls through to `:ok` for a
non-port. A transport that is not connected therefore *accepts* a request and never replies,
and the caller blocks for the full `call_timeout` (30 s default). Any new transport must make
that state an error rather than inherit the fallthrough.

### Gap 2: a remote server in `.mcp.json` is silently dropped

`Raxol.Agent.Code.McpConfig.parse_server/1` (`mcp_config.ex:80-90`) matches
`%{"command" => command}` and returns `nil` for anything else; `parse/1` rejects the nils
(`:73-78`). `Raxol.Agent.McpBundle.start_client/2` (`mcp_bundle.ex:113-122`) likewise requires
`:command` and otherwise yields `{:error, {:invalid_spec, spec}}`.

The config format `McpConfig` implements is the Claude Code / Claude Desktop format, and the
remote form of that format is exactly what a hosted vendor hands out:

```json
{ "mcpServers": { "intel-api": {
    "url": "…", "headers": { "Authorization": "Bearer …" } } } }
```

Today that entry produces no error, no log line, and no server: `/mcp` lists nothing and the
operator is given no reason. This is the one defect here that is user-visible before any new
capability lands, and it is the regression test that must fail before the change.

### Gap 3: the SSE module we have is the server

`Raxol.MCP.Transport.SSE` (`transport/sse.ex:1-41`) is a `Plug.Router` serving `POST /mcp`,
`GET /mcp/sse`, and `GET /health`, minting session ids for *inbound* clients. It is the
opposite direction. Its `if Code.ensure_loaded?(Plug.Router)` wrapper is, however, the house
pattern for an optional-dependency transport, and decision 8 below reuses it.

`raxol_mcp`'s runtime dependencies are `raxol_core` and `jason`, with `plug` optional. There is
no HTTP client in the package.

### Gap 4: the protocol constant is three revisions stale

`protocol.ex:11` pins `@mcp_protocol_version "2024-11-05"`, and `send_initialize/1` offers it
unconditionally. ADR-0033 establishes, with the revision date in the citation, that the
current specification (2026-07-28) is **stateless**: SEP-2575 removes `initialize` and
`notifications/initialized`, SEP-2567 removes `Mcp-Session-Id`, `server/discover` becomes
mandatory for servers, `ttlMs` and `cacheScope` are required on list results, and
`Mcp-Method` / `Mcp-Name` headers are required on Streamable HTTP posts. ADR-0033 also
concludes that upstream we must be a **dual-era client**, because a modern client talking to a
legacy server fails.

### Gap 5: the upstreams disagree with each other on the wire

From ADR-0033 §5 and the companion survey (`docs/proposals/web3-upstream-survey.md:67-88`),
measured on live handshakes rather than read from docs:

- Three session models across three servers: TronGrid stateful and concurrency-safe, TronScan
  stateful and **concurrency-hostile** (two parallel calls on one session both 500,
  reproducibly), ccscan fully stateless.
- Two SSE framings: TronGrid emits `data: {...}`, TronScan emits `data:{...}`. A strict parser
  breaks on one of them.
- `Accept: application/json, text/event-stream` is mandatory, and a response comes back as
  either SSE frames or plain JSON depending on the server.

A fourth variant appears on the commercial side: a per-account URL plus
`Authorization: Bearer`, documented as requiring no session handshake, serving a fixed set of
named tools plus third-party-listed tools that are **discovered at connect time and billed
per call**.

Four independent consumers, one missing capability.

## Decision

### 1. Extract a transport behaviour; keep exactly one session machine

`Raxol.MCP.Client.Transport`:

```elixir
@callback connect(config :: map()) :: {:ok, handle} | {:error, term()}
@callback send(handle, id :: pos_integer(), iodata()) :: {:ok, handle} | {:error, term()}
@callback close(handle) :: :ok
@callback decode_info(handle, message :: term()) ::
            {:messages, [binary()], handle}
            | {:failed, id :: pos_integer(), term(), handle}
            | :ignore
```

`Client` keeps `pending`, `next_id`, `status`, the tool cache, and every `handle_result/3`
branch. The transport owns connection, framing, and delivery. `decode_info/2` is what lets one
`handle_manager_info/2` clause serve a port message, an HTTP response chunk, or neither: the
`:ignore` return preserves today's catch-all at `client.ex:246`.

`send/3` carries the request id and returns the updated handle rather than `:ok`, because an
HTTP request is a round trip and not a write. A stdio transport ignores the id: one pipe
carries every request and the id only matters on the way back. An HTTP transport needs it
twice over. It has to associate a response with the request that caused it, and it has to be
able to fail one in-flight request without failing the connection, which is the `{:failed, id,
reason, handle}` arm and exactly what `send_to_port/2`'s fallthrough to `:ok`
(`client.ex:362`) cannot express today. The transport issues each request from a monitored
task and forwards what arrives, so the `Client` GenServer never blocks its own mailbox for a
whole round trip (which would make decision 6's `:pooled` policy meaningless), and a task that
dies fails exactly one pending entry rather than orphaning it.

Two adapters ship: `Transport.Stdio`, which is the existing port code moved behind `send/3`
with no behaviour change, and `Transport.Http`. The discriminator is `:command` XOR `:url`. A
spec carrying both, or neither, is `{:error, {:invalid_spec, spec}}`, never a silent preference
for one.

A second top-level client module was the obvious alternative and is rejected in
"Alternatives considered": the duplicated half is the id/pending/reply machinery, and
dual-era handshaking means keeping two copies of the part most likely to drift.

### 2. `Transport.Http` is dual-era, with the era probed per origin and cached

| | Modern (2026-07-28) | Legacy (2025-06-18 and earlier) |
| --- | --- | --- |
| Handshake | none | `initialize` then `notifications/initialized` |
| Capability discovery | `server/discover` per request | `initialize` result |
| Session | none | optional `Mcp-Session-Id`, echoed on every request |
| Required headers | `Mcp-Method`, `Mcp-Name` | `MCP-Protocol-Version` (2025-06-18) |
| List results | `ttlMs`, `cacheScope` required | absent |

Probe order: attempt `server/discover`. The origin is demoted to legacy **only** on a JSON-RPC
method-not-found for that call, or on HTTP 404, 405 or 501. A 401, 403, 408, 429 or 5xx is
health information rather than era information: it feeds `Raxol.MCP.CircuitBreaker` and leaves
the verdict untouched. That distinction is the difference between a transient upstream refusal
and a permanently wedged backend. A 403 challenge is not hypothetical on these upstreams:
ADR-0038's probe reproduces one on a live Blockscout instance, and treating it as era evidence
would cache `legacy` forever, after which every call sends an `initialize` that a modern server
is specified not to answer.

The verdict is cached as `{era, decided_at}` under a `{origin, path}` key with a TTL, so a
stale verdict expires on its own instead of waiting for a specific invalidating response. The
key carries the path because a gateway can serve several MCP endpoints under one origin, and a
per-origin key would hand all of them one era. A session-rejected response re-probes exactly
once, then fails.

The cache table has a named owner, because the shape an earlier draft of this decision reached
for does not exist. `:ets.new/2` tables are owned by the process that creates them
(`circuit_breaker.ex:31-33`, whose only caller creates its tables in a GenServer
`init_manager`, `registry.ex:264-278`), so there is no such thing as a public ETS table with no
owning process. A table created by the `Client` would make the verdict per client rather than
per origin, defeating the point; a table created by a transient process raises `ArgumentError`
in whoever still holds the reference. A supervised process in `raxol_mcp` owns it and hands the
reference out.

Legacy session state lives in the client process. This is the stateful-upstream side of the
boundary ADR-0033 §1 describes, and holding it in a supervised process per backend is the
reason that ADR gives for building the layer on the BEAM at all.

`Protocol` grows `supported_versions/0` and a negotiated per-connection version. The
**server** side keeps advertising `2024-11-05` until a separate decision; changing what we
serve is out of scope here and is listed under what this ADR does not decide.

### 3. Both content types, and a tolerant SSE parser

Every POST sends `Accept: application/json, text/event-stream` (survey finding 2 makes this
mandatory, not defensive). `content-type: application/json` yields one message;
`text/event-stream` yields a frame stream.

A new `Raxol.MCP.Client.SSE` parser is modeled on `Raxol.Earn.Transport.SSE.Parser`, which
splits on `\n\n` and has the caller buffer the remainder (`parser.ex:24-32`), with three
deliberate differences:

1. `data:` is accepted with or without the following space. The earn parser already does this
   (`parser.ex:62-63`), and it is the TronGrid/TronScan divergence.
2. `event:` and `id:` are **retained**, not dropped. The earn parser discards both by design
   (`parser.ex:34-41`), which is correct for its one-event-type stream and wrong here: legacy
   HTTP+SSE carries `event: endpoint`, and stream resumption needs the last id.
3. CRLF and bare CR line endings are accepted. The earn parser splits frames on `"\n\n"` only
   (`parser.ex:25`) and splits lines on `"\n"` only (`:46`), which is right for the one server
   it talks to. The SSE grammar permits `\r\n\r\n` and bare `\r`, and both TronGrid and
   TronScan sit behind edges that can normalize line endings, so a `\n`-only parser would turn
   one rewritten response into a single unbounded partial frame that never completes. Stated
   here rather than discovered.

Copying the EARN parser rather than depending on it is forced by the package graph:
`raxol_earn` sits above `raxol_payments`, and `raxol_mcp` depends only on `raxol_core` and
`jason`. That duplication is small, pure, and directly testable.

**Amended 2026-09-14, on implementation.** The same sentence does NOT excuse duplication
downward. `raxol_web3` depends on `raxol_mcp` by ADR-0033 decision 2, so anything pure that
both need has a home, and two things turned out to: the SSE frame parser (`raxol_web3` reached
for one to call SQD Portal's stateless MCP endpoint) and the bounded read loop this ADR's
decision 5 and ADR-0038's decision 4 each specified separately. Both were written twice and
then collapsed in the same change: the parser lives here and `Raxol.Web3.MCPCall` calls it, the
pure response accumulator lives in `raxol_core` beside `Raxol.Core.Outbound`, and the
Mint-touching send-read-close lives here because `raxol_core` must gain no dependency. Each
package keeps its own dial, its own connect-side error taxonomy and its own name for the stage.
"One design in two packages" was the right instinct and one implementation is the better end
of it.

### 4. Auth headers are resolved from references, and only where the configuration is trusted

Header values accept `${env:VAR}` and `op://…` references, resolved at connect time through
the same `op read` path `Raxol.Agent.Backend.Credentials` already uses (`credentials.ex:1-26`:
a reference-only store, so "no plaintext key ever touches disk"). A literal secret is accepted
(refusing it would just push operators to a worse workaround) and warned about once per
server.

**Resolution depends on where the spec came from, and that is the load-bearing half of this
decision.** `.mcp.json` is read from the workspace working directory
(`mcp_config.ex:42-43`, called as `McpConfig.load(cwd)` from `load_mcp/2` at
`app.ex:445-452` in the pre-change numbering; the `app.ex:389-398` this ADR first cited is
`load_session/2`), so it is
repository content: a file a clone can carry. Today nothing resolves from it, because
`parse_server/1` drops every remote spec (`mcp_config.ex:80-90`), which is the defect gap 2
exists to fix. Admitting remote specs and resolving references in the same change would turn a
cloned repository into an instruction to read a named environment variable, or a named
1Password item, and POST it to a host the repository chose. `Credentials.read_ref/2` passes the
reference to `op read` verbatim once it starts with `op://` (`credentials.ex:414-418`), so the
item path would be attacker-chosen, and the §7 target rules do not help: the destination is a
legitimate public address, and rule 2 exists to stop us reaching inward, not outward. So:

- A **workspace-sourced** spec may carry a `url`. Its header values must be literals, or names
  drawn from an operator-controlled allowlist that lives outside the workspace. A `${env:}` or
  `op://` reference in a workspace spec is refused with a named reason, logged once, and the
  server is skipped rather than started.
- A **user-level** spec (`~/.raxol/`, or an explicit operator flag) resolves references
  normally. That is the path an operator who configures a hosted server actually uses.

A jailed session already declines to read `.mcp.json` at all (`load_mcp(_cwd, true)`, at
`app.ex:443` before this change), so this rule is
for the single-tenant workspace that `McpLoader`'s own bounds describe as "merely careless
rather than hostile" (`mcp_loader.ex:23-31`). Reference resolution is what changes that
calculus, so the rule arrives with the capability rather than after it.

Resolved header values never reach a log line, a telemetry measurement, a cache key, an error
term, or a durable store. ADR-0033 §7 already requires this for upstream credentials and names
the error path as where it leaks in practice, so redaction is tested on the error path
specifically.

### 5. ADR-0033 §7's target rules bind here, enforced in one place

A hosted MCP URL is a caller-influenced outbound target exactly like a REST endpoint, so all
five rules apply inside `Transport.Http` rather than per backend: `https` only; every resolved
address checked against the reject set (loopback, link-local, RFC 1918, unique-local,
IPv4-mapped, `0.0.0.0/8`); the checked address is the address dialled; **redirects are not
followed**; timeout, response-size ceiling, and concurrency bounded per target.

Rule 3 is why decision 8 makes `mint` the optional dependency rather than `req`. Pinning means
dialling an `:inet.ip_address()` tuple while the hostname carries SNI, the certificate identity
and the `Host` header, and Req refuses that combination outright: it raises
`ArgumentError, "cannot set both :finch and :connect_options"`
(`deps/req/lib/req/finch.ex:546-548`), and without a named instance it starts an unreaped Finch
per pool option set (`:587-597`). ADR-0038 decision 3 reaches the same conclusion from the REST
side and records the mechanism in full; this transport takes the same shape so that rule 3 is
one design rather than two. **Amended 2026-09-14:** it is now one design in ONE place for the
part that can be shared. The dial stays per package, because each has its own connect-side
error taxonomy and `raxol_mcp`'s mint is optional where `raxol_web3`'s is required, but the
bounded read is `Raxol.MCP.BoundedExchange` and the pure response accumulator is
`Raxol.Core.Outbound.Response`, both called from both packages. Two byte-identical read loops
is what the earlier wording licensed and it was not the intent.

The redirect rule carries extra weight here that it does not in ADR-0033: this transport sends
an `Authorization` header, so following a 3xx would replay a bearer token at an
upstream-chosen origin.

### 6. Concurrency policy is declared data, defaulting to the safe value

`:stateless | :pooled | :serialized` per spec, matching ADR-0033's mitigation list. Legacy-era
origins default to `:serialized`, because TronScan fails 100% of the time on a parallel fan-out
over one session and the failure is invisible in a single-call test.

`Client` is a GenServer, so calls are already serialized on *entry*, but `pending` is a map and
nothing bounds the in-flight window: two callers get two concurrent requests on one session.
For a `:serialized` origin the in-flight cap is 1, and the excess is held in a **bounded**
queue that refuses with `{:error, :busy}` on overflow.

The queue has to be explicit, because the alternative is already a leak. `register_pending/3`
(`client.ex:370-372`) adds an entry and nothing but a reply, a JSON-RPC error, or
`{:exit_status, _}` (`client.ex:236-244`) ever removes one. An HTTP transport has no exit
status, and a caller whose `GenServer.call` times out at the 30 s default (`client.ex:91`,
`:99`) leaves its entry behind forever. Serializing makes caller-side timeouts the expected
outcome under fan-out, which is exactly the load that would grow `pending` without bound in a
long-lived remote client. So each request carries a timer: on expiry the `Client` replies
`{:error, :timeout}` itself and drops the entry, and a queued request that never dispatches is
refused rather than left to expire in the caller.

### 7. A per-call-priced tool is not a token-priced provider

Per-call-priced tools bill per invocation. ADR-0035 meters per token: `rates/2` returns an
`{input, output}` pair of per-million-token rates (`llm_prices.ex:75-84`), so a flat
per-call tool price has nowhere to live in that model and should not be stretched into it.

A remote tool therefore carries a declared `:price`, and:

- a non-nil price forces `sensitive: true` on the derived tool and reserves through
  `Raxol.Agent.SpendGate.around/4` at the existing `Raxol.Agent.ToolCall.Hook` seam
  (the `:tool_call_hooks` context key at `hook.ex:181`, read by `from_context/1` at `:185`;
  `hook.ex:44-59` is the moduledoc that describes the seam rather than the code);
- an unknown price on a metered origin is **denied by default**, which is the rule ADR-0033 §6
  already adopts by analogy from `Raxol.Agent.Backend.Resolver`: a free endpoint may be chosen
  automatically, a metered one only when explicitly configured.

`McpBundle` already defaults every bundled tool to `sensitive: true` (`mcp_bundle.ex:138`), so
the default posture is a deny under `ToolPolicy.deny_sensitive` and this decision only removes
the ability to opt *out* while a price is unknown. Extending ADR-0035's rate table to per-call
prices belongs to that ADR.

**The hook is where the reservation is made; the transport is where it is enforced.**
`Transport.Http` refuses to issue a `tools/call` for a priced tool unless the call carries a
reservation handle, returning `{:error, :unmetered_call}` otherwise. That is not redundancy.
`hook.ex:21-31` records that backends whose `handles_tools_internally?/0` returns true
(`Backend.Native`, the Claude Code and Cursor harnesses) drive their own tool loop and bypass
the seam entirely, so a native harness reaches the same transport with no hook in the path. The
bypass was tolerable while the seam gated capability, because the worst case was an ungated
read. It is not tolerable when the worst case is an unbudgeted spend incurred silently, and
deny-by-default on an unknown price does nothing on a path that never consults the price. One
enforcement site at the socket is the same argument ADR-0038 decision 2 makes for outbound
targets, applied to money.

The failure direction is deliberate and worth stating, because "hook" suggests the opposite:
`ToolCall.Hook` contains a hook `exit` as a veto and logs it (`hook.ex:82-89`), so a spend
ledger that is down denies the call rather than admitting it.

### 8. `mint` is an optional dependency, and `req` is not a dependency at all

`{:mint, "~> 1.8", optional: true}` and `{:castore, "~> 1.0", optional: true}` in `raxol_mcp`,
with the transport module behind `Code.ensure_loaded?` exactly as `Raxol.MCP.Transport.SSE`
already sits behind `Code.ensure_loaded?(Plug.Router)` (`transport/sse.ex:1`). Without `mint`,
an HTTP spec fails with `{:error, :no_http_client}`, which `McpBundle.load/2` already handles
as a per-server fail-open skip (`mcp_bundle.ex:94-100`).

Mint rather than Req for the reason decision 5 gives: Req cannot express a pinned dial, so a
Req-based transport could not implement §7 rule 3, which is the one rule this ADR is adding an
enforcement site for. Mint is also the smaller dependency of the two, since `req` pulls
`finch`, `mime` and `nimble_options` behind it and `mint` pulls only `hpax`.

This is not a style choice. ADR-0033 decision 2 rejects siting chain code in `raxol_mcp`
partly because it "would push `req` and every backend into the dependency footprint of every
raxol install", and `raxol_mcp` is a dependency of main `raxol`. A hard dependency here would
impose exactly the cost that ADR argued against, which is why this one is optional and why it
is the smallest client that can satisfy rule 3.

## Consequences

### Positive

- ADR-0033's primary Tron path and only Canton path become reachable by the client that ADR
  already plans to reuse. Nothing in its decision 6 table changes.
- Every hosted MCP server becomes configurable: the vendor set is open-ended, and remote
  entries in `.mcp.json` stop being silently discarded.
- One enforcement site for the §7 target rules, one credential-redaction path, and one SSE
  parser, instead of per-backend HTTP that ADR-0033 §7 calls "a security regression rather
  than a style problem".
- Rule 3 becomes one design across two packages, since this transport and ADR-0038's REST
  client pin the same way for the same reason.
- The stdio path is refactored behind a behaviour without behaviour change, so the existing
  client tests are the parity harness.
- `pending` stops leaking. The per-request timer this decision adds for the serialized queue
  fixes an entry leak that predates it on the stdio path too.

### Negative

- `Raxol.MCP.Client` gains a behaviour and two adapters where it had one inlined path: more
  modules for a package whose virtue is being small.
- A second SSE parser exists in the tree relative to `raxol_earn`'s, deliberately, until
  something lands in `raxol_core`. This mirrors the `Raxol.Web3.Cache` duplication ADR-0033
  already accepts. There is NOT a third: `raxol_web3` calls this one, because the graph lets it
  (see the amendment in decision 3).
- `raxol_mcp` now hosts a bounded send-read-close that `raxol_web3`'s guarded client depends
  on, which couples the read path of a package that must open TLS connections to a module
  behind an OPTIONAL `mint`. A build of `raxol_mcp` without mint therefore has to fail
  `raxol_web3` at boot rather than on its first request, which is an assertion rather than a
  type.
- Dual-era support means the protocol layer is a probe with a cached verdict rather than a
  constant. The verdict now carries a TTL and a narrow demotion rule, which bounds how wrong it
  can stay, at the cost of an occasional re-probe.
- `raxol_mcp` grows two optional dependencies, so there are now two build shapes to test, and
  the era-probe tests only run in the shape that has them.
- Per-call pricing arrives as a declared field with no authoritative source: a vendor that does
  not publish a pre-call price leaves us denying by default, which will look like a bug to an
  operator who has paid for the tool.
- Reference resolution is provenance-dependent, so the same `.mcp.json` entry behaves
  differently in the workspace and in `~/.raxol/`. That asymmetry is a support question, and it
  is the price of not shipping an exfiltration path.

### Mitigation

- The era verdict expires on a TTL and is invalidated by a session-rejected response, and the
  probe is exercised in tests against two reference servers shipped in `lib/` (the house
  convention ADR-0033 §3 sets: reference implementations in `lib/`, no mocking library). Those
  servers need `plug`, which is optional here, so CI runs the build shape where they run and
  their absence fails the run rather than skipping it.
- The in-flight cap for `:serialized` origins is property-tested with a concurrent fan-out,
  because the TronScan failure is the one that a single-call test cannot see. The same test
  asserts `pending` returns to empty, which is what catches a timer that did not fire.
- Header redaction is tested on the error path, and the address reject set against IP literals
  and IPv4-mapped addresses, per ADR-0033's mitigation list.
- The workspace-provenance refusal is a test that fails before the change: a workspace
  `.mcp.json` carrying `${env:}` or `op://` in a header must be refused with a named reason,
  and no `op` invocation may occur.
- The deny-on-unknown-price path logs the tool and origin explicitly, so the operator sees a
  reason rather than an absence, and the transport's `{:error, :unmetered_call}` is asserted
  with no hook in the pipeline, which is the native-harness shape.

### What this ADR does not decide

- What protocol revision the raxol MCP **server** advertises. Client-side negotiation lands
  here; the server keeps `2024-11-05` until that is decided on its own merits.
- Whether `Raxol.MCP.Aggregator` (ADR-0033 decision 1) re-serves remote tools, and under what
  allowlist. This decision only makes them reachable as a client.
- The per-call price table's shape and home, which belongs with ADR-0035.
- The shape of the operator-controlled header-name allowlist decision 4 refers to: where it
  lives and how it is edited. That it exists, and that a workspace spec cannot resolve a
  reference without it, is decided here.
- Any streaming or server-initiated-message support beyond what a response stream needs. The
  modern spec removed SSE resumability, `ping`, and `logging/setLevel`; the legacy `GET` stream
  is implemented only where a backend requires it for responses.
- Lifting a shared SSE parser or cache into `raxol_core`.

## Alternatives considered

### Shell out to `npx mcp-remote <url>` as a stdio proxy

Zero code, works today, and is what most hosts do. Rejected on three independent grounds.
`mcp_bundle.ex:171-180` already names the first, about unpinned `npx`: "unpinned remote code
execution in a credential-holding runtime". The second is that it puts one Node process per
remote server behind a runtime whose selling point is BEAM process economics. The third is
decisive: the ADR-0033 §7 target rules become unenforceable, because the request is built and
dialled inside a process we do not control, so scheme checks, address pinning, redirect
refusal, and header redaction all move outside our boundary. Decision 4's provenance rule
would go with them, since the proxy reads the config itself.

### A separate `Raxol.MCP.Client.Http` module

Rejected. The transport is ~60 of 395 lines; the duplicated remainder would be the JSON-RPC id
allocation, pending map, and reply paths, plus, with dual-era support, two handshake
implementations. That is the code where a divergence is a silent correctness bug.

### A bespoke REST client per vendor

A vendor with a dozen documented REST paths is a day of work and needs no protocol machinery
at all. Rejected because it forfeits the reason to prefer an MCP surface: where the tool set
is dynamic and discovered at connect time, a REST client is structurally unable to see tools
added after we ship. It also solves nothing for TronGrid, TronScan, or ccscan, and every
future vendor repeats the work.

### Wait for `raxol_web3`'s `mcp_proxy`

Rejected on direction. `mcp_proxy` is a *consumer* of this capability: ADR-0033 decision 6
lists `Raxol.MCP.Client` as reused infrastructure and the survey's wire-level findings are
written as constraints *on* `mcp_proxy`, not as a transport it supplies. The hole blocks that
ADR rather than being solved by it.

## Validation

Each claim class below is reproducible, and the first is the one that fails before the change.

1. **A remote `.mcp.json` entry produces a live server, and cannot resolve a reference.** Today
   a `{"url": …, "headers": …}` entry is dropped by `McpConfig.parse_server/1` with no
   diagnostic; the test asserts it is admitted, started, and lists tools. Two companions fail
   before the change for the opposite reason: a **workspace** spec whose header value is
   `${env:VAR}` or `op://…` is refused with a named reason and starts no server, and no `op`
   process is spawned while that test runs. Plus: a spec with both `:command` and `:url` is
   refused as `{:invalid_spec, _}`, and `McpLoader.admit/1`'s existing bounds (16 servers,
   `mcp_loader.ex:30-31`) still apply to remote specs.
2. **stdio parity.** The existing `Raxol.MCP.Client` suite passes unchanged against
   `Transport.Stdio` behind `send/3`, including the `:noeol` reassembly path and
   `{:exit_status, _}` handling.
3. **Era probe.** Two reference servers in `lib/`: one modern (answers `server/discover`,
   rejects `initialize`), one legacy (the reverse). The probe reaches `:ready` against both,
   caches the verdict under `{origin, path}`, and re-probes once on a session rejection.
4. **A refusal is not an era.** A server that answers `server/discover` but returns 403 once,
   then 200, ends up classified modern: the 403 records a breaker failure and leaves the
   verdict alone. This is the wedge test, and it fails against the demotion rule this ADR
   started with. Its pair: a demotion caused by a genuine `-32601` expires on the TTL.
5. **Framing tolerance.** Property test over `data:` with and without the space, `\n\n` and
   `\r\n\r\n` frame separators, frames split at every byte boundary, and interleaved `event:` /
   `id:` fields.
6. **Header compliance.** `Accept: application/json, text/event-stream` on every POST;
   `Mcp-Method` and `Mcp-Name` present on modern-era posts; no `Mcp-Session-Id` sent to a
   modern origin.
7. **Security.** `http://` refused; the address reject set enforced against IP literals,
   IPv4-mapped addresses, and a resolver that changes its answer between calls, with the dial
   going to the vetted address; a 3xx returns an error rather than being followed; no header
   value appears in any error term or log line.
8. **A serialized origin neither over-dispatches nor leaks.** A concurrent fan-out over one
   `:serialized` session issues exactly one request at a time, the excess beyond the queue bound
   is `{:error, :busy}`, and `pending` is empty once the fan-out settles, including for the
   requests that timed out.
9. **Metering.** A priced tool reserves through `SpendGate.around/4` before the HTTP call is
   built, and a refused reservation performs no request; an unknown price on a metered origin
   is denied with the tool and origin named; and a priced `tools/call` reaching the transport
   with no reservation handle, which is the native-harness shape, is `{:error,
   :unmetered_call}` with no request issued.

## References

- ADR-0033: Indexer-agnostic web3 data surface; decisions 1, 2, 6 and §7, whose reuse of
  `Raxol.MCP.Client` this decision is a prerequisite for
- ADR-0035: Cost metering for multi-rate providers; the token-rate model that per-call
  pricing does not fit
- ADR-0012: MCP as a rendering target; the server-side surface, unchanged here
- `docs/proposals/web3-upstream-survey.md:67-88`: the wire-level session, framing, and
  tool-count findings
- MCP architecture, 2026-07-28 revision (the current one):
  `https://modelcontextprotocol.io/specification/2026-07-28/architecture`
- SEP-2575, "Make MCP Stateless":
  `https://github.com/modelcontextprotocol/modelcontextprotocol/issues/2575`
- SEP-2567, "Sessionless MCP via Explicit State Handles":
  `https://github.com/modelcontextprotocol/modelcontextprotocol/issues/2567`
