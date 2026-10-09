# Raxol Broker

Fail-closed brokerage policy parsing, initialization and order evaluation, a
hash-chained decision journal, and a read-only Robinhood MCP session, for
Raxol. The package is pre-alpha. This release does not include order
execution, arming, or review.

## Policy

Initialize a policy with explicit monetary caps:

```sh
mix raxol.broker.init --max-notional 1000 --daily-cap 5000
```

The command writes `broker.policy.exs` in the current directory. If either flag
is omitted, it prompts only when connected to a real terminal; noninteractive
use must supply both flags. A prompt accepts the entered line with surrounding
whitespace trimmed; end of input (EOF) fails with a `Mix.Error` and writes
nothing.

The generated policy has all thirteen required keys. `Raxol.Broker.PolicyFile.new/2`
is the single constructor for it: given the two required caps it returns
`{:ok, policy}` with every default filled in, or `{:error, reason}`:

```elixir
{:ok, policy} =
  Raxol.Broker.PolicyFile.new(Decimal.new("1000"), Decimal.new("5000"))
```

The rendered file is:

```elixir
[
  max_notional_per_order: Decimal.new("1000"),
  daily_notional_cap: Decimal.new("5000"),
  max_position_weight: :unset,
  order_types: [:limit],
  options: false,
  advanced_orders: false,
  after_hours_market: false,
  symbols_allow: :unset,
  symbols_deny: [],
  max_orders_per_minute: :unset,
  drawdown_halt: :unset,
  llm_ask_above: :unset,
  ask_timeout: 30_000
]
```

| Key | Accepted value |
| --- | --- |
| `max_notional_per_order` | A `Decimal` strictly greater than zero. This cap is required and cannot be `:unset`. |
| `daily_notional_cap` | A `Decimal` strictly greater than zero. This cap is required and cannot be `:unset`. |
| `max_position_weight` | `:unset`, or a `Decimal` greater than zero and less than or equal to one. |
| `order_types` | A nonempty, duplicate-free list containing only the approved atoms `:market`, `:limit`, `:stop_limit` and `:stop_market`. |
| `options` | A boolean. |
| `advanced_orders` | A boolean. |
| `after_hours_market` | A boolean. |
| `symbols_allow` | `:unset`, or a nonempty, duplicate-free list of uppercase symbol strings such as `"AAPL"` or `"BRK.B"`. |
| `symbols_deny` | A duplicate-free list of uppercase symbol strings; may be empty. |
| `max_orders_per_minute` | `:unset`, or an integer from `1` to `10_000`. |
| `drawdown_halt` | `:unset`, or a `Decimal` greater than zero and less than or equal to one: the share of the start-of-day value today's loss may reach. |
| `llm_ask_above` | `:unset`, or a `Decimal` strictly greater than zero. |
| `ask_timeout` | An integer number of milliseconds from `1` to `4_294_967_295`; the generated default is `30_000` (30 seconds). |

`:unset` means that the corresponding optional threshold is not configured and
its rule abstains, except `llm_ask_above`, where `:unset` asks for every
model-originated order. It is valid only for the optional keys; it never
satisfies either required notional cap.

Policy files are data, not executable Elixir. The loader size-bounds the file,
parses it with existing atoms only, and accepts only the keyword-list literals
shown by this schema. Decimal values must use the exact
`Decimal.new("...")` form. Other calls, variables, operators, any other alias,
`throw`, `exit`, and side effects are rejected without being executed. Invalid,
malformed, or oversized policies fail closed, and a file that is not valid
UTF-8 returns `{:error, {:parse_error, path, :invalid_utf8}}`.

Before parsing, the loader rejects symlinks and applies the trust rules of
`Raxol.Agent.OperatorFile.trusted?/1`: the file must be a regular file owned by
the account the VM runs as, with no group- or other-write bit, in a parent
directory that meets the same owner and mode rule or is sticky. Otherwise
loading returns `{:error, {:untrusted_file, path, reason}}`. A missing file or
a directory returns the missing-file or non-regular-file error instead.

Initialization renders and validates the complete policy before touching the
destination. It creates a same-directory staging file with mode 0600 before
writing to it, writes and syncs it, then applies the same file and directory
trust checks before publishing the final name atomically without replacement.
An unsafe destination directory is refused without leaving a policy or staging
file. An existing file or symlink is left unchanged, and the staging file is
removed after successful publication or an ordinary error.

## Evaluating an order

```elixir
{:ok, intent} = Raxol.Broker.Intent.buy_usd("AAPL", Decimal.new("250"), provenance: :llm)

Raxol.Broker.Policy.evaluate(intent, %Raxol.Broker.Policy.Context{policy: policy, ...})
# => {:allow, intent} | {:ask, [{rule_id, prompt}]} | {:deny, {rule_id, detail}}
```

`Raxol.Broker.Intent` constructors validate model-supplied input and return
`{:error, reason}` instead of raising; `:provenance` (`:strategy`, `:llm`,
`:human` or `{:untrusted, source}`) is required. `Raxol.Broker.Policy.evaluate/2`
reads only the intent and its `Raxol.Broker.Policy.Context` (portfolio value,
positions, quotes, today's notional, orders in the last minute, market session,
review warnings) and does no I/O. Its rules run through
`Raxol.Agent.Authorization.Engine`: any DENY wins, otherwise any ASK, otherwise
ALLOW. `Policy.rule_ids/0` lists the stable rule ids in evaluation order; the
`Raxol.Broker.Policy` moduledoc describes each rule.

Caps are inclusive. A rule that needs a context field left `nil` denies; an
invalid policy or a context field of the wrong type denies before any rule
runs. Untrusted provenance always asks. Cancels are always allowed.

Caller data crosses one boundary, `Raxol.Broker.Plain`: binaries, atoms,
integers, proper lists and tuples, non-struct maps, decimals (a
coefficient of at most 40 digits and an exponent in -40..40) and
`DateTime`s, checked by pattern matching only, so no caller protocol
implementation (Enumerable, Inspect, String.Chars) ever runs on it.
`Intent.normalize/1` and `Policy.Context.normalize/1` rebuild each struct
from plain fields, and the executor, the journal and `Policy.evaluate/2`
each normalize caller data before using it. `evaluate/2` denies non-plain
data with `{:intent, reason}` or `{:context, reason}`.

## Executor

`Raxol.Broker.Executor` is the one path every order takes: policy, the
order's `review_*` tool, policy again with the review's warnings, then
`placing` and the order tool, each step journaled before the next.

```elixir
{:ok, policy} = Raxol.Broker.PolicyFile.load("broker.policy.exs")

children = [
  {Raxol.Broker.Supervisor,
   executor: [session: mcp_client_spec, account_number: "...", policy: policy]}
]

executor = Raxol.Broker.Executor

{:ok, intent} =
  Raxol.Broker.Intent.limit(:buy, "AAPL", qty, price,
    provenance: :strategy,
    id: "dip-2026-10-02"
  )

case Raxol.Broker.Executor.run(executor, intent, context) do
  {:ok, %{status: status, journaled: true}} -> {:sent, status}
  {:ok, %{journaled: false, journal_error: reason}} -> {:sent_unrecorded, reason}
  {:ok, :duplicate} -> :already_placed
  {:ask, token, prompts} -> {:needs_human, token, prompts}
  {:deny, _group_id, {rule_id, _detail}} -> {:denied, rule_id}
  {:error, reason} -> {:nothing_sent, reason}
end
```

Under `Raxol.Broker.Supervisor` the executor starts after the journal and
restarts with it (`:rest_for_one`); the new executor closes any group the
old one left open, including parked ASKs. The supervisor always binds the
executor to its own journal: an `:executor` `:journal` naming another one
makes `start_link/1` return `{:error, {:journal_mismatch, given}}`.

The executor's `init` touches only the journal: it validates its options,
prepares the MCP session without connecting (a live session still fails
start), resolves and monitors the journal, claims it, and closes the groups
left open. The session connects after `init`, without blocking the
executor. Until it is ready, `run/3` and `approve/3` return
`{:error, :port_not_ready}` and open nothing;
`Raxol.Broker.Executor.await_port(executor, timeout \\ 30_000)` returns
`:ok` once it is; a timeout above 4_294_000_000 ms is
`{:error, {:invalid_timeout, :await_port, timeout}}`. When the connection
fails, the session client dies while connecting, or the session dies, the
executor stays up, logs it and reconnects after a backoff (`:reconnect_ms`,
default 1 s, doubling to 60 s, reset once ready). A down endpoint therefore
never restarts the executor and cannot exhaust the supervisor's restart
budget, and nothing needs restarting by hand. A port that drops after the
review but before the place closes the group as `port_not_ready` without
writing `placing`, and a re-run of the same intent places once the port is
back.

`Raxol.Broker.Executor.child_spec/1` sets `shutdown` to the place timeout
plus 5 s (35 s with the defaults), or to the `:shutdown` start option, a
positive integer. A stop during a place waits up to that bound for the
order call; a review in flight is not waited for. Journal writes have their own bound, `:write_deadline`, so a
journal stall that outlasts the shutdown bound ends with the executor
killed; on restart the group closes as `crash_outcome_unknown`, which keeps
counting and is never placed again. The executor
dispatches at most one queued run or approval per callback, so no callback
runs two place calls and the bound covers the place in progress.

A person answers an ASK later with `approve(executor, token, "name")`,
`decline(executor, token, "name")` or `close(executor, token, reason)`.

* **Policy is the executor's.** The `:policy` start option (validated by
  `PolicyFile.validate/1`) replaces the context's `policy`, and
  `today_notional`, `orders_last_minute` and `review_warnings` are
  replaced too. Quotes, positions, portfolio values and `market_session`
  are still taken from the caller until #1185 sources them.
* **Review is mandatory.** `Raxol.Broker.Executor.Place` is the only module
  that names an order tool, and it refuses without a `ReviewReceipt` for
  the same intent and group (an HMAC over the whole intent), verified under
  a key the executor generates at start and keeps in its own process
  dictionary; in any other process there is no key and every receipt is
  refused. The journal also refuses `placing` for a group without a review
  followed by an ALLOW or an approval. A test checks the compiled code for
  order tool calls outside `Place`.
* **Threat model.** The BEAM cannot stop code that deliberately writes
  into another module's private state, e.g. `Process.put` into its slots
  or `:sys.replace_state`. The guarantee is that no path through public
  APIs can send an order tool without the executor's review pipeline.
  Every remaining bypass requires impersonating the executor's private
  process-dictionary slots on purpose.
* **No caller code runs in the executor.** `run/3` rebuilds the intent
  and context from plain data (`Intent.normalize/1`,
  `Policy.Context.normalize/1`) in the caller and again inside the
  executor before anything else; a failure is
  `{:error, {:invalid_intent, reason}}` or
  `{:error, {:invalid_context, reason}}`, with nothing journaled or sent.
  An unrecognised call is `{:error, :unknown_request}`. `:journal` must be a
  registered name (an atom) or a pid; anything else, such as
  `{:via, mod, name}` or `{:global, name}`, is `{:invalid_journal, value}`,
  checked first. The `:clock` fun runs in a short-lived Task with a 5 s
  budget, outside the executor's process; a clock that is not a zero-arity
  fun is `{:invalid_clock, value}` at start, and one that crashes or
  returns anything but a UTC `DateTime` fails the call with
  `{:error, {:context, reason}}` and sends nothing. The clock's result
  passes `Plain.normalize/1` and must be an ISO-calendar `Etc/UTC`
  `DateTime`, otherwise the call is
  `{:error, {:context, {:invalid_clock, _}}}` with no group and no order.
  Terms from other processes (messages, exit reasons, call arguments) are
  only ever inspected with `structs: false`, which a structure test
  enforces for the executor and journal modules. The receipt key enters
  the executor's process dictionary only after its claim succeeds.
* **Bounded timeouts.** `:review_timeout`, `:place_timeout` and
  `:reconnect_ms` must be integers in 1..4_294_000_000 ms, which leaves
  headroom under the VM's timer limit; anything else refuses start with
  `{:invalid_timeout, key, value}`.
* **Any review warning asks.** A warning turns ALLOW into ASK
  (`:review_warning`); a review response that cannot be read counts as one.
  `approve/3` reads the counters again, journals the approval and re-runs
  the policy: a cap reached while the ASK waited still denies. `decline/3`
  and `close/3` end the group. A bad approver name raises in the caller
  and leaves the group parked.
* **Counters come from the journal.** Decisions are serialized, so two
  callers cannot both pass the daily cap. The daily window is a rolling
  24 hours back from the executor's clock, and no caller input moves it,
  until #1185 adds a trading calendar the executor owns. Queued callers
  are monitored, and a queued run whose caller has died is dropped, never
  dispatched. Queued calls run in order; a new call never jumps ahead.
* **One executor per journal.** The executor claims the journal at start;
  only a process started as an executor can claim, a second one fails with
  `{:journal_claimed, pid}`, and the journal takes any group record
  (`open_group`, `append_to_group`, `append_group`, every entry type) only
  from the claimant: another process gets `{:error, {:not_claimant, id}}`,
  and with no claim held every group write is `{:error, :unclaimed}`.
  Nothing is written either way. The claimant check comes before the
  journal reads anything the write carries; only then does it rebuild the
  intent and context from plain data (`{:invalid_intent, reason}` or
  `{:invalid_context, reason}` otherwise) and encode them. Fills are not
  group records. The claim lives in the journal's memory, so the executor
  monitors the journal and stops with `{:journal_down, reason}` when it
  goes down; its supervisor restarts it, and the new one claims again.
  Callers waiting on it get an exit. A group left open or parked before an
  executor restart is closed with `executor_restarted`.
* **Idempotent.** An intent id with a `placing` whose outcome is not
  `:failed` returns `{:ok, :duplicate}` and sends nothing, across
  restarts. Each place carries a `ref_id` derived from the intent id,
  which Robinhood deduplicates on. Give intents a stable `:id` for this to
  work.
* **Fail closed.** Any journal error before `placing`, review error or
  unsupported order kind means no order. Once the order call is made the
  result is `{:ok, _}`: a place call that times out is journaled
  `:unknown` and keeps counting, and an order response the journal could
  not record comes back with `journaled: false`. While the port is not
  connected the executor stays up and refuses with
  `{:error, :port_not_ready}` until it reconnects.
* **Dry run only for now.** Only `mode: :dry_run` runs. The session must
  be marked `sandbox: true` and its URL must not be on `robinhood.com`,
  otherwise it is refused as live before connecting. `mode: :armed` is
  `{:error, :not_armed}` until `mix raxol.broker.arm` exists.

Only equity orders (`review_equity_order`, `place_equity_order`) and equity
cancels are mapped until the generated tool adapters land; options and
advanced orders are refused with `{:error, {:no_adapter, kind}}`.

## Decision journal

`Raxol.Broker.Journal` records every order decision in one hash-chained
journal per install, `~/.raxol/broker/journal` (override with
`$RAXOL_BROKER_JOURNAL` or the `:path` option). Start it through
`Raxol.Broker.Supervisor` (`:rest_for_one`, journal first), passing journal
options under `:journal`. Group records are written only by the process
holding the journal's claim, the executor, so callers go through
`Raxol.Broker.Executor`; the sequence below is what it writes.

Each Writer call has a deadline, `:write_deadline` (default 60 s). A write
that misses it may still land, so the journal never reports it as an
error: it kills the Writer and stops with `{:writer_stalled, ms}`, and the
executor stops with it. The kill does not promise that nothing lands, since
a dirty IO NIF already running can finish the write after it. Both
restart, and recovery reads what reached disk: a `placing` that landed closes as `crash_outcome_unknown` and keeps
counting, and one that did not leaves its group closed as
`crash_before_verdict`. A fsync slower than the deadline costs a restart;
in exchange a dead disk cannot hang every order and cancel behind it.

```elixir
children = [{Raxol.Broker.Supervisor, journal: []}]

{:ok, group} = Raxol.Broker.Journal.open_group(intent, context)
:ok = Raxol.Broker.Journal.append_to_group(group, {:verdict, :pre_review, Policy.evaluate(intent, context)})
:ok = Raxol.Broker.Journal.append_to_group(group, {:review, review_response})
:ok = Raxol.Broker.Journal.append_to_group(group, {:verdict, :post_review, verdict})
:ok = Raxol.Broker.Journal.append_to_group(group, {:approval, :approved, "operator"})
:ok = Raxol.Broker.Journal.append_to_group(group, {:placing})
# only now call place_*
:ok = Raxol.Broker.Journal.append_to_group(group, {:order, :placed, order_response})
```

A group is the intent, a snapshot of the policy context, each verdict, any
human approval of an ASK, the review response, a `placing` record, and one
terminal record: the order response (`:placed`, `:failed` or `:unknown`), a
DENY verdict, a declined approval, or `{:close, reason}`. `open_group/2` makes
the intent durable before any review or order call; `append_group/1` writes a
whole group as one contiguous run. Every record is synced before the call
returns.

`{:placing}` is the write-ahead point for the order call. The journal prices
the order from the group's own intent and context (`Policy.notional/2`) and
refuses an order it cannot price, so nothing unpriced can be sent. An order
response is refused for a group with no `placing` record. Order and review
responses are recorded as given, with floats written as decimal strings.

Each record carries `prev_hash` and `hash` (SHA-256 of its canonical JSON),
so changing, removing or truncating any committed record is detected. The
journal directory is created mode 0700 and its files 0600, and a symlinked,
foreign-owned or group- or other-writable directory is refused. On start the
journal verifies the chain:

  * A damaged journal answers every append and query with
    `{:error, {:journal_damaged, offset}}`; `status/0` and `verify/0` name
    the offset. No order can be sized against it.
  * A group left open by a crash is closed before anything else is written.
    Without a `placing` record it becomes DENY `crash_before_verdict`. With
    one, the order call may have gone out, so it becomes
    `crash_outcome_unknown` and keeps counting toward the caps.

The chain has no key: it catches corruption and naive edits, not someone who
can rewrite the whole directory.

The policy context reads from an index built on start and kept current:

```elixir
{:ok, notional} = Raxol.Broker.Journal.today_notional(start_of_exchange_day_utc)
{:ok, count} = Raxol.Broker.Journal.orders_last_minute(DateTime.utc_now())
{:ok, pnl} = Raxol.Broker.Journal.realized_pnl_today(start_of_exchange_day_utc)
```

An order counts from the moment its `placing` record is written, at the
notional recorded there, and stops counting only when its order response says
`:failed`. Placed, in-flight and unknown-outcome orders all count; cancels,
denials and groups that never reached `placing` do not. The live index and the
one rebuilt at start agree. The caller chooses the day boundary.
`realized_pnl_today/1` sums the realized P&L recorded with `append_fill/1`.

### A damaged journal

A damaged journal stops trading until an operator acts. There is no repair:
the chain exists so history cannot be edited. To recover:

1. Stop the broker and keep the damaged directory as evidence
   (`mv ~/.raxol/broker/journal ~/.raxol/broker/journal.damaged-<date>`).
2. Run `mix raxol.broker.replay --date <today> --journal <archived path>` to
   see the offset of the first broken record.
3. Do not trade again until the next exchange day. A new journal starts with
   empty counters, so on the day of the move it knows nothing about orders
   already placed: today's notional and order rate would start from zero.

### Replay

```sh
mix raxol.broker.replay --date 2026-10-02 [--journal PATH]
```

Prints every group opened that day (UTC) in journal order: intent, context,
each rule's verdict for each policy pass, review, approval, placing, order,
and outcome. Rules before a denying rule show `pass` (they allowed or asked)
and rules after it `not run`, because the policy stops at the first DENY.
Control characters in recorded text are printed escaped, never raw. The task
reads without taking the writer lock, so it works while the broker runs, and
refuses a journal whose chain does not verify.

## Fake server

`Raxol.Broker.MCP.Fake` stands in for Robinhood's MCP server in tests, dry
runs and backtests. It needs no account and opens no socket.

```elixir
fake =
  Raxol.Broker.MCP.Fake.start(
    quotes: %{"AAPL" => "125.00"},
    warnings: [],
    reject: ["GME"],
    order_states: ["queued", "confirmed", "filled"],
    faults: [{"place_equity_order", {:http, 429}}]
  )

children = [
  {Raxol.Broker.Supervisor,
   executor: [session: Raxol.Broker.MCP.Fake.session(fake), account_number: "FAKE-0001", policy: policy]}
]

Raxol.Broker.MCP.Fake.calls(fake)     # tools/call that reached it, with arguments
Raxol.Broker.MCP.Fake.requests(fake)  # every exchange, :pending until it answers
Raxol.Broker.MCP.Fake.orders(fake)

{:ok, session} = Raxol.Broker.MCP.Client.start_link(Raxol.Broker.MCP.Fake.client_opts(fake))
```

`client_opts/2` gives the read-only session a synthetic credential that can
never refresh, so a dry run never reads your stored credential or reaches
Robinhood's token endpoint (`mcp_opts/1` alone does not isolate it). That
session retries a `429`, `502`, `503` or `504` with jittered doubling backoff
(`:backoff` option), within the caller's timeout and never far enough to open
its circuit breaker; the executor's order port never retries.

`:accept` (or `Fake.accept/2`) limits the bearer tokens the Fake answers;
any other gets the 401 Robinhood answers an invalid token. `forbid_calls/1`
answers every `tools/call` 403, and `server/discover` always gets
Robinhood's plain-text 400.

## Tool catalog

Every tool is classified from the frozen capture in
`priv/robinhood/tools_list.json` (`Raxol.Broker.Tools.Catalog`): `:read`,
`:review` (`review_*_order`, `preview_*_order`), `:write` (an explicit
allowlist: `place_*_order`, `cancel_*_order`, `replace_*_order`, alert
create/update) or `:unknown`. A tool the capture lacks, a write-shaped tool
outside the allowlist, or a review or write tool whose schema changed on the
live server is `:unknown`, and the executor and the read-only session refuse
it. Each connect diffs the live list against the capture and logs the drift.

The read tools are generated as typed functions that validate arguments
against the captured schema before sending:

```elixir
{:ok, result} = Raxol.Broker.Tools.MarketData.get_equity_quotes(session, %{"symbols" => ["AAPL"]})
```

To refresh the capture from a signed-in account, then regenerate:

```sh
mix raxol.broker.capture_tools
mix raxol.broker.gen.tools          # --check fails if the checked-in modules are stale
```

The checked-in capture is Robinhood's live list of 2026-10-06 (76 tools):
50 are readable, `review_equity_order`, `review_option_order` and
`preview_crypto_order` are the review tools, and the equity, option and
crypto `place_*`/`cancel_*` tools plus alert create/update are the writes.

## Robinhood sign-in

```elixir
:ok = Raxol.Broker.Login.run()
{:ok, session} = Raxol.Broker.MCP.Client.start_link([])
{:ok, tools} = Raxol.Broker.MCP.Client.list_tools(session)
{:ok, result} = Raxol.Broker.MCP.Client.call(session, "get_accounts", %{})
```

`Login.run/1` opens the browser on Robinhood's consent page and waits for the
redirect on `http://127.0.0.1:<port>/callback`. The endpoints are pinned in
`Raxol.Agent.Auth.Robinhood`; discovery metadata is fetched only to confirm
them, and any difference stops the sign-in. The client registers itself
(dynamic client registration, public client, PKCE S256), and the callback must
carry the `state` it sent and `iss` equal to
`https://agent.robinhood.com/mcp/trading`. The resulting credential is written
encrypted; nothing is stored if any step fails.

### Credential at rest

`Raxol.Broker.CredentialStore` keeps the credential in
`~/.raxol/broker/robinhood.credential` (override with
`$RAXOL_BROKER_CREDENTIAL`) as an AES-256-GCM envelope. The 256-bit key lives
in 1Password when the `op` CLI is installed, otherwise in the macOS login
keychain (service `raxol.broker.credential-key`, account `robinhood`). On any
other system without `op` there is no key store, and the store returns
`{:error, {:keychain_unavailable, :unsupported_os}}` instead of writing.

The keychain item is created by `security`, so any process running as the
same user can read it without a prompt. The keychain protects copies of
`~/.raxol` that leave the machine (backups, dotfile sync), not the running
account. The key is written over stdin and never appears in a process's
arguments.

### Session

`Raxol.Broker.MCP.Client` is the only path to the MCP server. It refreshes the
token shortly before it expires. On a 401 it refreshes once, however many
callers are waiting, stores the rotated refresh token before using the new
access token, and retries each request once. If the refreshed token is refused
too, every call returns `{:error, :unauthorized}` until you sign in again; the
session stops talking to the server but does not crash.

Only the tools Robinhood marks read-only (`get_*`, `preview_scan`, `run_scan`,
`search`) can be called. Orders, cancels, reviews, watchlist, alert and scan
changes, and unknown names return `{:error, {:tool_denied, name}}` without a
request, and `list_tools/1` lists only the allowed tools.
