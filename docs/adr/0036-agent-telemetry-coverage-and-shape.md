# ADR-0036: Agent telemetry coverage and shape

## Status

Proposed, 2026-09-05. A spike: tier 1 (the money path) is implemented and proven in this
change; tiers 2-5 are scoped, estimated and sequenced here, not built.

Written against the tree as it stood the day after ADR-0035's implementation landed in the
working tree (`LlmPrices.turn_cost_usd/4` exists and `Code.App` calls it at `code/app.ex:1150`
pre-change). Everything below was re-measured with the AST scanner
`Raxol.Core.Telemetry.Invariants.scan_lib!/1` and by reading emit sites, not by regex. Where
the brief that commissioned this spike was wrong, the correction is recorded where it lands
rather than quietly amended; there are seven of them, listed in "What the brief got wrong". Two
of my own predictions were wrong too, and they are in "Gap 3"; a third mid-spike claim, that the
`params` leak was live at Symphony's call site, is corrected in "Gap 4".

Depends on ADR-0035 for the metering semantics the tier-1 events observe, and on the
telemetry-invariant mechanism (`Raxol.Core.Telemetry.Invariants`,
`Raxol.Core.Telemetry.InvariantSentinel`) for the classification every event must carry.

## Context

### What exists

Six registries classify every `[:raxol, ...]` event a package emits as exactly one of
`:invariant`, `:peer` or `:operational`, and a per-test sentinel fails any test in which an
`:invariant` fires undeclared. The criterion, applied literally: if a peer, the network, the
chain, the filesystem, the clock, or a user can cause it, it is not an invariant. `raxol_agent`
declares one invariant (`[:raxol, :agent, :acp_turn_runner, :interrupt_failed]`,
`agent/telemetry.ex:65`); `raxol_agent_client_protocol` declares two
(`agent_client_protocol/telemetry.ex:62`, `:105`).

Two registries matter here and neither is built on the shared macro. `Raxol.Agent.Telemetry`
is a hand-written `@events` map (`agent/telemetry.ex:54-132` pre-change) and its completeness
test is a **regex** over `lib/` that counts a doc or comment mention as an emit
(`test/raxol/agent/telemetry_registry_test.exs:36`, `:21-23`). That is how five `:policy` names
that are built at runtime (`policy_applier.ex:156`) pass as "classified": a comment names them.
`scan_lib!/1` sees 16 static names after this change and the registry holds 21; the five are
exactly the runtime-built policy members (measured with a `scan_lib!` versus `events/0` diff,
"Validation" below).

### What the brief got wrong

Re-derived with `scan_lib!/1` from `packages/raxol_core` and by reading sites.

| Brief said | Measured | How |
| --- | --- | --- |
| ~9 emit sites, 9 events in `raxol_agent` | 13 `:telemetry.execute` call sites, **12** static names plus one runtime-built family of 5 members; registry rows: 17 | `scan_lib!("../raxol_agent/lib")`; AST walk of every `:telemetry.execute` in `lib/` |
| 14 ACP events | **13** by `scan_lib!`; registry rows: **17** | `scan_lib!("../raxol_agent_client_protocol/lib")`; `agent_client_protocol/telemetry.ex:47-106` |
| `scan_lib!/1` is authoritative | It under-counts ACP by 4: `[:raxol, :acp, :attach, :granted]`, `[..., :attach, :denied]`, `[..., :delivery]`, `[..., :journal, :non_holder_turn_completed]` are emitted through `apply(:telemetry, :execute, [literal, ...])` (`delivery.ex:82`, `reattach.ex:359`, `journal/writer.ex:494`) and a local `telemetry/3` helper (`ext/attach_policy.ex:239`, `:259`); neither shape is in `@emit_functions` (`invariants.ex:85`) | read the four sites |
| `[:raxol, :agent, :policy, sub]` "can never be subscribed to or enforced" | It is subscribed to today: `ThreadLogRouter` attaches to the five concrete names (`thread_log_router.ex:53-60`, `:91`). What is impossible is proving the member set from source, so the family cannot be scanned or enforced; it is `:operational` anyway, so enforcement was never at stake | read `thread_log_router.ex` |
| 38 of 45 log sites have no telemetry within 400 chars | **34** of 45. The 11 with telemetry: `turn_runner.ex:772/777/783/788/980`, `reader.ex:224`, `writer.ex:542`, `file_backend.ex:212`, `session.ex:636`, `snapshot.ex:358`, `hook.ex:272` | every site read (`LogSiteReader` pass, 45 rows) |
| `emit_bridge.ex:259` and `tool_converter.ex:118` are invariant-shaped | Neither is. `emit_bridge.ex:259`'s only reasons are `:journal_open_failed` and `:journal_append_failed` (`emit_bridge.ex:329-341`), both from `FileStore`: the filesystem, or a live foreign lock holder (`writer.ex:165-180`). `tool_converter.ex:118`'s only reason is `{:invalid_hook_return, hook, value}` from a **user-supplied** hook (`hook.ex:229`, `:255`) | read both modules |
| A span's `:exception` leaf is a strong invariant candidate, per `raxol_terminal` | Not on the turn path. `raxol_terminal` earns it because the wrapped bodies contain no I/O and no user code (`terminal/telemetry.ex:62-75`). Every turn-path boundary runs user code inside the wrap: `:req_plugins` (`http.ex:52`), Action modules and `Dynamic.invoke` (`dynamic.ex:30`), `:tool_authorizer` and hooks (`tool_converter.ex:96`, `:196`) | read the four candidate bodies |

The correlation claim in the brief ("only 4 of 9 `raxol_agent` and 3 of 14 ACP events carry
`session_id`/`turn_id`") survives re-measurement in substance: of the 12 pre-change static
`raxol_agent` events, `done_gate.*` (2) carry `turn_id`, `journal.checkpoint.surrogate` carries
`session_id`, `session.register_timeout` carries `key`; nothing else carries either. ACP:
`attach.*` (2) and `journal.non_holder_turn_completed` carry `session_id`; `delivery` carries
`session` and `turn` under different key names (`connection_delivery_test.exs:580-582`).

### Gap 1: the money path emitted nothing

Pre-change, `code/app.ex`, `code/cost_ledger.ex`, `llm_prices.ex` and `benchmark_profile.ex`
contained zero emit sites (`scan_lib!` output, no `:cost` or `:budget` name). ADR-0035 fixed
the metering **semantics**; nothing observed them. Specifically unobservable:

- **Which step priced a turn.** `LlmPrices.turn_cost_usd/4` (`llm_prices.ex:103-108`
  pre-change) returned `{:ok, cost}` and dropped which of `reported`, the scoped table or the
  flat table produced it. A provider that stops reporting cost degrades silently to a table
  row that may be 20x off (ADR-0035, "Gap 5"), and nothing could tell.
- **An unpriced turn.** `flag_unpriced/4` (`code/app.ex:1072-1083` pre-change) noticed a $0.00
  turn that burned tokens only when a ledger **and** a policy were wired, and recorded it as a
  field on the model. The single-user configuration, which gets neither halt nor estimate
  (ADR-0035, "Gap 1"), could not see the hole at all.
- **A halt.** `enforce_budget/1` (`:1098-1109`) halted by killing the worker and writing a
  status line (`halt_turn/2`, `interrupt/1` at `:901`). No message, no event.

### Gap 2: no latency signal, and no single "turn" to measure

Zero `:telemetry.span/3` calls exist in `raxol_agent`, `raxol_agent_client_protocol` or
`raxol_symphony` (`TurnBoundaryMapper` pass, item 11; the only repo-wide spans are in
`raxol_speech` and `raxol_watch`). Zero `monotonic_time` reads sit on a turn, backend or tool
boundary; the ten that exist are deadlines (`mcp_bundle.ex:76`, `actions/shell.ex:106`,
`lsp/pool.ex:268`, ...), not durations. `BenchmarkProfile`'s struct has no duration field
(`benchmark_profile.ex:29-37`).

"A turn" is four different things:

| Notion | Where | Process | Span-able in place? |
| --- | --- | --- | --- |
| One provider call | `Backend.HTTP.complete/2` `http.ex:47-68` | caller's | **yes**, sync |
| One tool call | `ToolConverter.dispatch_tool_call/3` `tool_converter.ex:81` | loop's | **yes**, sync; the one LLM-reachable chokepoint both loops route through (`stream.ex:534`, `tool_executor.ex:665`) |
| One ReAct loop (1..N provider calls, N defaults to 10) | `Stream.react/2` `stream.ex:164`; loop in a `spawn_link` at `:231`; `complete/2` at `:449` | spawned | **no**: `react/2` returns a lazy `Stream.resource`; a span around it measures microseconds |
| One library turn | `Raxol.Agent.Turn.run/3` `turn.ex:44-69` | caller's | **yes**, sync; includes `after_turn/4` (curation) |
| One ACP `session/prompt` | `TurnRunner.start_turn/3` `turn_runner.ex:345` to its return; owns `turn_id` (`:351`) and `session_id` (`:379`) | Session's root Task | **yes**, sync from the runner's frame |
| One coding-TUI turn | `Code.App` `start_turn/2` `app.ex:826` to `finalize_turn/2` `:1483`, error `:1493`, or halt `:1111` | three processes deep (`app.ex:871`, `:875`, `stream.ex:231`) | **no**: cross-process, three exits, no `started_at` or `turn_id` on the model (`app.ex:139-203`) |

`Contract.pump` emits `:turn_completed` once per tool round (`contract.ex:464`) and once at the
end (`:524`), so `Code.App` meters every one as a paid call (correct: each is a provider call,
`app.ex:1034`) while `Raxol.Symphony.Orchestrator.maybe_turn_increment/1`
(`orchestrator.ex:1974-1980`) counts every one as a turn (wrong: the runner maps both
`{:turn_complete, _}` and `{:done, _}` to `event: :turn_completed`, `runners/raxol_agent.ex:882-894`,
so a prompt with N tool rounds counts N+1). The brief was right to flag this.

### Gap 3: 34 conditions reported only to `Logger`

45 `Logger.warning`/`Logger.error` sites in `packages/raxol_agent/lib`; 34 have no telemetry.
Clusters: `scheduler.ex` 10, `session.ex` 3 of 4, `lsp_context.ex` 3, `turn_runner.ex` 1 of 6
(`:704`), `lsp/pool.ex` 2, `orchestrator.ex` 2, `tool_executor.ex` 2, `session_inbox.ex` 2,
`writer.ex` 2 of 3, and eleven singletons.

The scheduler is the worst of them. `dispatch_fire/3` records the fire, hands the work to an
unlinked `spawn/1` (`scheduler.ex:249`, default `dispatch` at `:602`) and advances the schedule
unconditionally (`:246-252`, `advance/2` at `:257-269`). There is no retry, no failure counter,
and `fire_count` increments regardless of outcome (`:251`). A recurring job whose runner fails
every fire re-fires forever and is visible only to a log grep.

**Prediction, written before any site was read:** by name, 8 of the 34 looked invariant-shaped
(`emit_bridge.ex:259`, `tool_converter.ex:118`, `turn_runner.ex:704`, `session.ex:351`,
`:365`, `session_inbox.ex:299`, `:302`, and the three scheduler "returned a non-contract
shape" arms), and I predicted **2** would survive reading: `emit_bridge` and `tool_converter`.

**Result after reading all 34:** the reader pass found 2 candidates and they were **not the two
I named**: `session.ex:351` (EmitBridge crashed; a raxol-owned `BaseManager` running no user
callback, `emit_bridge.ex:189-260`) and `session.ex:383` (a linked process exited abnormally;
the comment at `session.ex:378-380` says nothing links to the Session today). Applying the
criterion strictly demotes both: a supervisor that exhausts the bridge's shutdown timeout
delivers `:killed`, which is not in `[:normal, :shutdown]` (`session.ex:348`) and is
shutdown timing, not a defect; and any user process may `Process.link/1` to a Session and die.
So the honest count is **0 of 34** safe invariants, in line with the two prior passes
(1 of 17, 0 of 13). Name-based intuition was wrong on both of my picks, in the same direction
as before: conditions that read as "our pipeline lost data" or "contract violated" turn out to
sit at an injection seam: a user hook, an injected runner, the filesystem, a peer subprocess.
Nearly every log-only site in this package is at such a seam, which is why so few qualify.

### Gap 4: correlation is impossible

See the table under "What the brief got wrong". No `raxol_agent` cost, session-lifecycle or
tool event carried a `session_id`; two ACP events use `session`/`turn` where three others use
`session_id`. A consumer cannot join a halt to the turn that caused it.

A related finding in the existing surface, **fixed in this change**: `[:raxol, :agent, :policy,
:applied]`, `:cache_hit` and `:cache_miss` put `params` (the wrapped operation's argument,
typed `term()`) into metadata, and `ThreadLogRouter` persisted the whole metadata map to the
durable thread log. I first wrote here that the one production caller passes the prompt. That
was wrong: Symphony's runner passes `%{turn:, issue_id:}` (`runners/raxol_agent.ex:487`) and
closes over the prompt in `op` (`:563`), so in-repo the leak was latent. The hazard was the
API shape, an arbitrary term dumped into persisted metadata, and any consumer using a
`Policy.Cache` keyed on a prompt, the natural use of a cache policy around an LLM call, would
have written prompts into its audit log. `params` is gone; `params_digest` (64 bits of
SHA-256 over the term's external format) replaces it on all three events, and callers that
need correlation keys pass them as `PolicyApplier.apply/4`'s `metadata:` option. Symphony
passes its two ids that way.

An adversarial pass on the first version of that fix found it moved the leak from certain to
possible: `metadata:` was identifiers-only by prose, and `ThreadLogRouter.handle/4` still
mirrored the entire metadata map into the durable entry. Both are now enforced by one
definition, `Raxol.Agent.Telemetry.identifier?/1` (an atom, a number, or a binary of at most
64 bytes; every id this repo mints fits, no prompt does). `apply/4` raises on a `metadata:`
value that fails it, naming the offender by shape rather than content so the refusal cannot
itself leak. The router persists only an allowlist of correlation keys (`session_id`,
`turn_id`, the four `TraceContext` ids, and whatever the attaching host names in `attach/4`'s
`:metadata_keys`), and only when the value passes the same predicate; anything else is
dropped, not raised on, because `:telemetry` detaches a handler that raises and a lost audit
trail is the worse failure. The event's own fields were already in the payload, so the
narrower mirror loses nothing.

The same pass raised five more against the fix and the tier-1 prototype, all addressed here:

- **The digest was unkeyed.** A truncated SHA-256 resists recovery, not confirmation: anyone
  holding the audit log and a candidate argument (a known template with a short secret in it)
  could confirm it offline. `Raxol.Agent.Telemetry.digest/1` is now HMAC-SHA256 under a
  32-byte key generated once per VM run (`:persistent_term`) and never persisted. The stated
  stability claim was also too strong (external term format is not canonical across OTP
  versions, and a term holding a pid or a fun encodes differently each time), and the key
  makes the honest claim structural: a digest joins within one run and never across runs.
- **It was computed twice per call, unmeasured.** Now once per `apply/4`, on the context every
  event merges, so every event of one operation (`:cache_*`, `:retry_*`, `:timeout`,
  `:applied`) shares it and the argument is serialized exactly once. Measured on Apple M1 with
  pre-built terms, two runs: **3 us at 1 KB, 90 us at 100 KB, 1.1 ms at 1 MB**; the key costs
  about 40% over an unkeyed hash. The one production caller wraps an LLM turn measured in
  seconds.
- **`reason` and `key` were emitted verbatim.** `reason` is whatever the wrapped operation
  returned (a provider error may echo the request or carry a response struct with headers);
  `key` is a user's `key_fn` over the argument. Both now pass through
  `Raxol.Agent.Telemetry.bound/1`, which keeps identifiers, walks tuples, lists and maps to a
  depth of 3 and a width of 8, and replaces every other leaf with a shape tag
  (`{:redacted, :binary, 4096}`, `{:redacted, Req.TransportError}`), so the shape of an error
  survives and its content does not. The router applies `bound/1` to every payload it persists
  as the backstop for an emitter that forgets. Cost: 0.2 us on a provider-error reason.
- **`sandbox.denied` persisted tool arguments.** `{:shell_denied, mode, command}` carried the
  full command line into the `:sandbox_deny` audit entry, and the two `*_malformed_payload`
  reasons carried the whole tool payload. `SandboxHook` now emits `{:shell_denied, mode,
  program}` with a `command_digest` beside it, reduces malformed-payload reasons to their tag,
  bounds `mode` (a predicate becomes `{:redacted, :function}`) and everything else; the
  caller's `{:deny, reason}` is untouched. `program` is the first token only when the command is
  simple (`Sandbox.Shell.simple_command?/1`); otherwise it is the tag `:non_simple`. The
  adversarial pass on the first cut found why: list modes deny every assignment-prefixed
  command, and `PGPASSWORD=hunter2 psql` has the secret as its first token, so "emit the
  program" was "emit the credential" on exactly the commands guaranteed to reach this emit.
  This is the explicit decision the review asked for: an audit line says `rm` was refused and
  a known command can be matched by digest; the arguments, where a model embeds a secret,
  never leave the process.
- **A sub-agent round emitted `turn_id: nil`.** It runs inside its parent's turn, and the ADR's
  own recommended query (sum cost by `turn_id`) would have dropped its spend. It now inherits
  the running turn's id from the model's last folded event, which is sound because
  `Contract.pump` emits `turn_started` before any tool, and so any sub-agent, can start
  (`contract.ex:285`).

And one against the rule set: the two halts were split "because remedies differ", yet
`:over_limit` folded `:ledger_unreachable` (a dead process, whose remedy is infrastructure)
in with cap limits under a `limit` discriminator. It is now its own event,
`[:raxol, :agent, :budget, :halt, :ledger_unreachable]`, proven from `raxol_payments`' suite by
stopping the ledger mid-turn, and rule 1 below now states the principle it was applying.

### Gap 5: a runtime-built name defeats the scanner, not the subscriber

`PolicyApplier.emit/2` builds `[:raxol, :agent, :policy, event_name]` (`policy_applier.ex:156`).
Consumers subscribe fine (`ThreadLogRouter`), and the sentinel would arm fine if any member
were `:invariant` (none is). What breaks is completeness: `scan_lib!` cannot enumerate the
members, so a `scan_lib!`-based registry test cannot demand them, and the current regex test
accepts a comment mention instead. The value of fixing it is registry honesty, not
subscribability.

### What consumes these events, and where they could go

Exactly one non-test consumer of `[:raxol, :agent, *]` exists: `ThreadLogRouter`
(`thread_log_router.ex:91`), opt-in, attached by nobody in `lib/` (`agent.ex:89-92` tells the
host to do it), reading metadata only and ignoring measurements (`:112`). Zero non-test
consumers of `[:raxol, :acp, *]`. `web/` consumes Phoenix and VM metrics only
(`web/lib/raxol_playground_web/telemetry.ex:26-63`); `packages/raxol_liveview/lib` has no
`Telemetry` reference. Test suites pin shapes for eleven `raxol_agent` events and two ACP
events (`ConsumerFinder` pass, section 2); the two that pin measurements are
`snapshot.persist_redacted_by_heuristic` (`%{count: 1}`, `snapshot_test.exs:376`) and
`acp.delivery` (`%{count: 1}`, `connection_delivery_test.exs:580`).

There is no OpenTelemetry SDK in any `mix.exs` or `mix.lock`. `Raxol.Core.Metrics.Cloud`
(`lib/raxol/core/metrics/cloud.ex`) is a hand-rolled OTLP/HTTP JSON sender with a SigNoz
service variant (`:354`, `:376-378`, default endpoint `:4318/v1/metrics` at `:69-70`), fed by
`Raxol.Core.Metrics.MetricsCollector` (`metrics_collector.ex:83`) and **never by a
`:telemetry` handler**. `raxol_earn`'s application says SigNoz export is "pending the
ansible-riddler collector pipeline" (`raxol_earn/application.ex:32-33`). `:telemetry_metrics`
is a root dependency (`mix.exs:345`) with no `Telemetry.Metrics` definition for any
`[:raxol, ...]` event anywhere. Two pipelines, disjoint.

### Overhead, measured

A throwaway `mix run` script in `packages/raxol_agent` (deleted after the spike; the method is
the whole of it): each operation timed with `:timer.tc/1` over 200k iterations after 1k
warm-up, handlers attached with `:telemetry.attach/4` on a module-less fun, Apple M1, OTP 28,
two runs; ranges are across the runs.

| Operation | ns/op |
| --- | --- |
| `Map.put` + float multiply (baseline) | 151-161 |
| `LlmPrices.turn_cost_usd/4`, flat table | 481-503 |
| `:telemetry.execute/3`, 0 handlers | 46-57 |
| `:telemetry.execute/3`, 1 no-op handler | 167 |
| `:telemetry.execute/3`, 1 ETS-counter handler | 207 |
| `:telemetry.execute/3`, 10 no-op handlers | 578 |
| `:telemetry.span/3`, 0 handlers | 375-571 |
| `:telemetry.span/3`, 1 no-op handler on start and stop | 466 |

One span costs about as much as the pricing call it would sit next to, roughly 0.5 us, or
0.03% of a 2 ms frame. A provider call is hundreds of milliseconds; a tool call is
milliseconds. Overhead is not a constraint on any boundary proposed below; the constraint is
what a **handler** does, since it runs in the emitting process. `automated_monitor.ex:319`
already writes ETS on the hot path and `telemetry_logger.ex:47` logs synchronously; neither
subscribes to agent events, but they are the pattern a consumer of these must not copy on the
turn path.

## Decision

### Five rules every event obeys

1. **One event per condition.** A name never carries both a happy path and a failure
   (`raxol_earn` has zero expressible invariants for this reason). A discriminator in metadata
   is allowed only when every member would be classified identically, none is a happy path,
   and every member has the same **remedy class**: a price to add, a policy to change, or a
   process to repair. Members with different remedy classes get their own names, which is why
   there are three halt events and why `:frozen` (an operator's policy decision) stays under
   `:over_limit` while `:ledger_unreachable` (a process to repair) does not.
2. **Static names only.** No runtime-built segment. The varying part goes in metadata.
3. **Measurements are numbers; metadata is context.** A duration, a count, a token count, a
   dollar amount is a measurement. `wall_ms` in metadata (`policy_applier.ex` timeout event,
   `thread_log_router.ex:42`) is the existing violation.
4. **Correlation core.** Every agent event carries `session_id` where a session exists and
   `turn_id` where a turn exists; `agent_id` where an agent exists. These are trace and log
   attributes, never metric labels.
5. **Cardinality tiers, decided per key.** Label-safe (bounded atoms): `backend`, `source`,
   `kind`, `limit`, `stage`, `reason` atoms, `decision`, `policy_kind`, tool **class**.
   Attribute-only (unbounded): `session_id`, `turn_id`, `model`, `job_id`, `key`, `path`,
   raw tool name. Forbidden anywhere: prompts, tool arguments, `params`, file contents, wallet
   addresses, credentials. Justification against the deployment: SigNoz's metric path is
   ClickHouse-backed and `signoz_check_metric_cardinality` exists because unbounded labels are
   the failure mode; its logs and traces paths index attributes and are where `session_id`
   belongs.

### Tier 1: the money path (built)

Five events, all `:operational`, emitted from `Code.App`'s fold. The resolution order is
ADR-0035's; the events only observe it.

| Event | Fires when | Measurements | Metadata |
| --- | --- | --- | --- |
| `[:raxol, :agent, :cost, :priced]` | a metered provider call resolved to a cost (any amount, including a priced model with an empty usage frame) | `cost_usd`, `input_tokens`, `output_tokens` | core + `source` (`:env`, `:reported`, `:scoped_table`, `:flat_table`), `backend`, `model`, `kind` (`:llm_turn`, `:llm_subagent`), `ledger?` |
| `[:raxol, :agent, :cost, :unpriced]` | `flag_unpriced/4`'s exact predicate: cost is `0.0` and tokens were billed, **whether or not** a ledger and policy arm the halt | `input_tokens`, `output_tokens` | core + `source` (`:unknown`, or `:env` with zero rates), `backend`, `model`, `kind`, `armed?` |
| `[:raxol, :agent, :budget, :halt, :unpriced]` | `enforce_budget/2` stops a running turn because the previous call was unpriced | `%{count: 1}` | core + `backend`, `model` (the unpriced name), `kind` |
| `[:raxol, :agent, :budget, :halt, :over_limit]` | `enforce_budget/2` stops a running turn because the ledger refused | `%{count: 1}` | core + `backend`, `model`, `kind`, `limit` (`:per_request`, `:session`, `:lifetime`, `:frozen`, `:invalid_amount`) |
| `[:raxol, :agent, :budget, :halt, :ledger_unreachable]` | `enforce_budget/2` stops a running turn because the wired ledger did not answer (`CostLedger.check/3` caught an exit) | `%{count: 1}` | core + `backend`, `model`, `kind` |

A call with no billed tokens and no price emits nothing: a local backend reporting `usage: %{}`
(`http.ex:788`) says nothing about money, and an event there would fire on every ollama turn.
The consequence is a known blind spot shared with `flag_unpriced/4`: a hosted provider whose
trailing usage frame is empty is indistinguishable from a free one at this site. That is
ADR-0035's fallback branch, and it is named rather than papered over.

`source` is carried by a new public function `LlmPrices.turn_cost/4` returning
`{:ok, cost, source} | :unknown`; `turn_cost_usd/4` delegates to it and every one of its
existing assertions is unchanged (`llm_prices_turn_cost_test.exs`, 13 tests, "Validation").
The `:env` source is stamped by `Code.App`, the only party that reads the environment.

Answer to open question 4, on whether an event at `flag_unpriced` is worth having if the guard
arms only under a ledger and policy: the **condition** is detectable in every configuration;
only the **halt** is gated. So `:unpriced` fires unconditionally with `armed?` saying whether
a halt will follow, and the halt is a separate event. That is the shape change the question
implies, and it is what makes the default single-user configuration observable for the first
time.

What is deliberately not in tier 1's prototype and remains in its estimate:

- The submit-time refusal (`app.ex:775-777`, `budget_exhausted/1` before `start_turn/2`).
  Proposed name `[:raxol, :agent, :budget, :refused]`, `%{count: 1}`, metadata core +
  `limit`. Same file, same shape; not built because it fires before a `turn_id` exists and the
  correlation core for it needs deciding (session only).
- The ACP runner's own budget (`turn_runner.ex:339` `Budget.check/0`, `:603` `Budget.record/1`),
  which is a token cap in a different module and package layer. Unscoped here; it is a second
  money path and should get the same four shapes once the `raxol_agent` ones have shipped.
- An `:unmetered` event for "no usage reported at all". Considered; deferred, see above.

### Tier 2: latency (scoped)

Four `:telemetry.span/3` sites, all new names, all in-process synchronous, none converting an
existing counter:

| Span prefix | Wraps | Stop metadata | Notes |
| --- | --- | --- | --- |
| `[:raxol, :agent, :backend, :complete]` | `http.ex:47-68` body | `backend`, `model` (billed, from `metadata.model`), `provider`, `usage` token counts as measurements | covers both loops (`stream.ex:449`, `tool_executor.ex:253`) without touching either. `session_id`/`turn_id` must ride in via `opts` or a process-dictionary context; neither is in scope at `:47` today |
| `[:raxol, :agent, :tool, :dispatch]` | `tool_converter.ex:81` body | `tool_class` (`:auto_allow`, `:consequential`, `:dynamic` from `ToolClassifier`), `call_id`; raw `name` attribute-only | the chokepoint both loops route through. Do **not** wrap `tool_executor.ex:423` `run_one/2`: `gated_run/4` at `:465` blocks on a human and would bury operator latency in tool duration |
| `[:raxol, :agent, :turn, :run]` | `turn.ex:44-69` | `conversation_id`, `agent_id`, `user_id` | includes `after_turn/4` (curation, user-model refresh); decide whether that is turn latency or its own span before building |
| `[:raxol, :agent, :acp_turn_runner, :turn]` | `turn_runner.ex:345` `start_turn/3` | `session_id`, `turn_id`, `stop_reason` | the ACP turn. Prefer it over a Session-level span (`session.ex:369` to `:803`), which is cross-process and would need a `started_at` on `%Turn{}` (`session.ex:35-53`) |

Every `:exception` leaf is `:operational`, per "What the brief got wrong". Every `:start` and
`:stop` leaf is `:operational`. Twelve registry rows. The span at the backend chokepoint
strictly nests inside the turn spans (1..N per turn) and the tool span nests inside that
(0..M per round); a consumer sums levels, never across them.

The coding-TUI turn (`Code.App`) is **not** a span in this tier. It needs `turn_id` and a
monotonic `turn_started_at` added to the model, and three exits (`final?`, error, halt) that
must each emit a `:stop`, with a leaked span on any missed exit. It is tier 2b, sequenced after
the four sync spans prove the shape.

**Public contract.** These are additive names, so no consumer breaks and no migration is
needed. The brief expected tier 2 to convert existing counters into spans; it does not, because
none of the twelve existing static events measures a duration-shaped thing and converting
`[:raxol, :agent, :policy, :timeout]` (the one with a `wall_ms`) would break `ThreadLogRouter`
(`thread_log_router.ex:42`) and `policy_applier_test.exs:300`. That change belongs to tier 4,
below, with its migration.

### Tier 3: promote the log-only conditions (scoped)

Promotion means: keep the `Logger` line for humans, add a `:telemetry.execute/3` in the same
clause immediately after it (the shape at `writer.ex:541-548` and `hook.ex:271-278`). Not all 34
deserve it. The ones that do, all `:operational`:

| Event | Sites | Measurements | Metadata | Why this and not others |
| --- | --- | --- | --- | --- |
| `[:raxol, :agent, :scheduler, :run_failed]` | `scheduler.ex:282`, `:285`, `:288` | `%{count: 1}` | `job_id`, `trigger`, `outcome` (`:error`, `:bad_return`, `:crash`), `recurring?` | autonomous work that can fail forever in silence. Never `prompt` (`scheduler.ex:317` puts it in the thread-log payload; it must not reach telemetry) |
| `[:raxol, :agent, :scheduler, :delivery_failed]` | `:300`, `:303`, `:306` | `%{count: 1}` | `job_id`, `outcome` | same. `target` is attribute-only if included at all; it may be a chat id |
| `[:raxol, :agent, :scheduler, :thread_log_failed]` | `:329`, `:332`, `:335` | `%{count: 1}` | `job_id`, `trigger`, `outcome` | the adapter runs inline in the GenServer (`:312-316`); a failing adapter loses every fire's audit record |
| `[:raxol, :agent, :scheduler, :job_dropped]` | `:507` | `%{count: 1}` | `job_id` | a persisted job silently deleted on replay |
| `[:raxol, :agent, :emit_bridge, :durable_dropped]` | `emit_bridge.ex:259` | `%{count: 1}` | `session_id`, `reason` (`:journal_open_failed`, `:journal_append_failed`), `type` (the event type atom) | the highest-severity log-only site: a durable event is lost permanently and the only compensating signal today is a contract `:error` on the session stream, which no dashboard sees |
| `[:raxol, :agent, :tool_call_hook, :invalid_return]` | `tool_converter.ex:118` | `%{count: 1}` | `hook` | sits beside the existing `tool_call_hook.exit`; a user hook returning the wrong shape is a class of bug worth counting |
| `[:raxol, :agent, :session, :emit_bridge_crashed]` | `session.ex:351` | `%{count: 1}` | `session_id`, `reason` | provisionally `:operational` (see Gap 3). Promote to `:invariant` only after a full-suite run with it armed shows zero fires; that is the empirical procedure, not intuition |
| `[:raxol, :agent, :session, :lifecycle_crashed]` | `session.ex:365` | `%{count: 1}` | `session_id`, `reason` | user `app_module` code runs inside Lifecycle (`session.ex:466-469`); operational by construction |

Twelve of the remaining 26 log sites are the shape "an injected function raised" at a seam the
library user owns (`tool_executor.ex:646/650`, `session_inbox.ex:299/302`, `process.ex:326`,
`self_improve.ex:136`, `orchestrator.ex:358/500`, `lsp/pool.ex:185/313`, `lsp_context.ex:350/535/816`)
and are adequately served by their log line; promote them only when a consumer asks. The rest
(`curator.ex:209`, `writer.ex:173/599`, `stdio_agent.ex:305`, `mcp_bundle.ex:95`,
`turn_runner.ex:704`) are filesystem or startup conditions with an existing higher-level
signal.

### Tier 4: the metadata contract (scoped)

Codified as the five rules above and enforced by a registry-adjacent test that reads each
event's emit site for the core keys. Changes to the existing surface:

| Change | Breaking? | Migration |
| --- | --- | --- |
| Add `session_id`/`turn_id` to `journal.write_failed`, `journal.damaged`, `tool_call_hook.exit`, `sandbox.denied`, `acp_turn_runner.*` where in scope | no (additive keys) | none |
| ACP `delivery`: add `session_id`/`turn_id` beside `session`/`turn` | no (additive) | deprecate `session`/`turn` in the registry row comment and CHANGELOG; remove at the next major |
| `policy.timeout`: move `wall_ms` to measurements | **yes** (`ThreadLogRouter`, `policy_applier_test.exs:300`) | emit in both places for one minor release; registry row and CHANGELOG deprecation note; drop from metadata at the next major |
| `policy.applied/cache_hit/cache_miss`: `params` removed, `params_digest` added, `metadata:` option added to `apply/4` | **yes**: an external handler reading `metadata.params` now gets `nil` | none. Shipped as a clean cutover in this change because the alternative was a release that kept leaking; recorded under Security in the CHANGELOG with the removed key named. The one in-repo consumer (Symphony's runner test, `raxol_agent_policy_test.exs:134`) asserted the ids through `params` and now asserts them through `metadata:` |

`raxol_agent_client_protocol` declares `:telemetry` as `only: [:dev, :test]`
(`agent_client_protocol/mix.exs:55`) and guards every emit with `Code.ensure_loaded?/1`
(`session.ex:1008`, `connection.ex:1558`, `delivery.ex:81`). Any tier-4 edit there inherits that
guard and the lesson attached to it: prove the event fires through a real handler in a suite
where the guard is genuinely true.

### Tier 5: static names and honest registries (scoped)

1. Replace `PolicyApplier.emit/2` with five literal `:telemetry.execute/3` calls. No consumer
   sees a change: the names are already concrete on the wire.
2. Move `Raxol.Agent.Telemetry` onto `use Raxol.Core.Telemetry.Invariants` and replace the
   regex completeness test with `scan_lib!/1`, so a comment can no longer stand in for an emit.
   `Raxol.Agent.Test.InvariantSentinel` (`test/support/invariant_sentinel.ex`) is then replaced
   by the core sentinel.
3. Teach `scan_lib!/1` the two shapes it misses (`apply(:telemetry, :execute, [ev | _])` and a
   local helper named `telemetry`), or normalize the four ACP sites to `emit_telemetry/2`, before
   pointing a `scan_lib!` test at that package; otherwise it reports four phantom rows.

### Event catalog: the whole surface of the two agent packages

Measurements and metadata for existing rows were read off the emit sites (an AST walk of every
`:telemetry.execute/3` in `raxol_agent/lib`, "Validation"), not off the registry comments.
"core" means `session_id` and, where a turn exists, `turn_id`. Status: **new** (this change),
**proposed** (a later tier), **changed** (an existing row whose shape a later tier alters, with
the tier), **unchanged**.

#### `raxol_agent`

| Event | Measurements | Metadata | Class | Status |
| --- | --- | --- | --- | --- |
| `[:raxol, :agent, :acp_turn_runner, :interrupt_failed]` | `%{}` | `stage`, `detail` | invariant | unchanged; tier 4b adds core |
| `[:raxol, :agent, :acp_turn_runner, :journal_failed]` | `%{}` | `stage`, `detail` | operational | unchanged; tier 4b adds core |
| `[:raxol, :agent, :done_gate, :ungated_done]` | `%{}` | `turn_id` | operational | unchanged |
| `[:raxol, :agent, :done_gate, :rejected_evidence]` | `%{}` | `turn_id`, `reason` | operational | unchanged |
| `[:raxol, :agent, :journal, :checkpoint, :surrogate]` | `%{}` | `op`, `session_id`, `tip_offset` | operational | unchanged |
| `[:raxol, :agent, :journal, :damaged]` | `%{count: 1}` | `dir`, `segment` | operational | unchanged; tier 4b adds `session_id` |
| `[:raxol, :agent, :journal, :write_failed]` | `%{}` | `stage`, `reason` | operational | unchanged; tier 4b adds `session_id` |
| `[:raxol, :agent, :policy, :applied]` | `%{}` | `policy_kinds`, `outcome`, `params_digest`, + caller `metadata:` | operational | **changed in this change**: `params` -> `params_digest` (breaking) |
| `[:raxol, :agent, :policy, :cache_hit]` | `%{}` | `policy_kind`, `key` (bounded), `params_digest`, + caller `metadata:` | operational | **changed in this change** (`params`, `key` bounded); tier 5 (static emit site) |
| `[:raxol, :agent, :policy, :cache_miss]` | `%{}` | `policy_kind`, `key` (bounded), `params_digest`, + caller `metadata:` | operational | **changed in this change**; tier 5 |
| `[:raxol, :agent, :policy, :retry_attempt]` | `%{}` | `policy_kind`, `attempt`, `reason` (bounded), `backoff_ms`, `params_digest`, + caller `metadata:` | operational | **changed in this change** (`reason` bounded); tier 5 |
| `[:raxol, :agent, :policy, :retry_exhausted]` | `%{}` | `policy_kind`, `attempt`, `reason` (bounded), `params_digest`, + caller `metadata:` | operational | **changed in this change** (`reason` bounded); tier 5 |
| `[:raxol, :agent, :policy, :timeout]` | `%{}` | `policy_kind`, `wall_ms` | operational | **changed**, tier 4b: `wall_ms` becomes a measurement (breaking); tier 5 |
| `[:raxol, :agent, :sandbox, :denied]` | `%{}` | `action`, `reason` (shell: `{:shell_denied, mode, program}` with `program` the first token of a simple command or `:non_simple`; malformed payloads: the tag), `command_digest` | operational | **changed in this change**: the command line and malformed payloads no longer leave the process; tier 4b adds core |
| `[:raxol, :agent, :session, :register_timeout]` | `%{count: 1}` | `key`, holder detail | operational | unchanged |
| `[:raxol, :agent, :snapshot, :persist_redacted_by_heuristic]` | `%{count: 1}` | `path` | operational | unchanged |
| `[:raxol, :agent, :tool_call_hook, :exit]` | `%{}` | `hook`, `reason` | operational | unchanged; tier 4b adds core |
| `[:raxol, :agent, :cost, :priced]` | `cost_usd`, `input_tokens`, `output_tokens` | core, `kind`, `backend`, `model`, `source`, `ledger?` | operational | **new** |
| `[:raxol, :agent, :cost, :unpriced]` | `input_tokens`, `output_tokens` | core, `kind`, `backend`, `model`, `source`, `armed?` | operational | **new** |
| `[:raxol, :agent, :budget, :halt, :unpriced]` | `%{count: 1}` | core, `kind`, `backend`, `model`, `source` | operational | **new** |
| `[:raxol, :agent, :budget, :halt, :over_limit]` | `%{count: 1}` | core, `kind`, `backend`, `model`, `source`, `limit` | operational | **new** |
| `[:raxol, :agent, :budget, :refused]` | `%{count: 1}` | `session_id`, `limit` | operational | proposed, tier 1 remainder |
| `[:raxol, :agent, :backend, :complete, :start / :stop / :exception]` | `system_time` / `duration`, token counts / `duration` | `backend`, `model`, `provider`; core via opts | operational (all three leaves) | proposed, tier 2a |
| `[:raxol, :agent, :tool, :dispatch, :start / :stop / :exception]` | `system_time` / `duration` / `duration` | `tool_class`, `call_id`; `name` attribute-only; core via context | operational (all three) | proposed, tier 2a |
| `[:raxol, :agent, :turn, :run, :start / :stop / :exception]` | `system_time` / `duration` / `duration` | `conversation_id`, `agent_id`, `user_id` | operational (all three) | proposed, tier 2a |
| `[:raxol, :agent, :acp_turn_runner, :turn, :start / :stop / :exception]` | `system_time` / `duration` / `duration` | core, `stop_reason` | operational (all three) | proposed, tier 2a |
| `[:raxol, :agent, :code, :turn, :start / :stop]` | `system_time` / `duration` | core, `exit` (`:final`, `:error`, `:halt`) | operational | proposed, tier 2b |
| `[:raxol, :agent, :scheduler, :run_failed]` | `%{count: 1}` | `job_id`, `trigger`, `outcome`, `recurring?` | operational | proposed, tier 3 |
| `[:raxol, :agent, :scheduler, :delivery_failed]` | `%{count: 1}` | `job_id`, `outcome` | operational | proposed, tier 3 |
| `[:raxol, :agent, :scheduler, :thread_log_failed]` | `%{count: 1}` | `job_id`, `trigger`, `outcome` | operational | proposed, tier 3 |
| `[:raxol, :agent, :scheduler, :job_dropped]` | `%{count: 1}` | `job_id` | operational | proposed, tier 3 |
| `[:raxol, :agent, :emit_bridge, :durable_dropped]` | `%{count: 1}` | `session_id`, `reason`, `type` | operational | proposed, tier 3 |
| `[:raxol, :agent, :tool_call_hook, :invalid_return]` | `%{count: 1}` | `hook`; core via context | operational | proposed, tier 3 |
| `[:raxol, :agent, :session, :emit_bridge_crashed]` | `%{count: 1}` | `session_id`, `reason` | operational (provisional) | proposed, tier 3 |
| `[:raxol, :agent, :session, :lifecycle_crashed]` | `%{count: 1}` | `session_id`, `reason` | operational | proposed, tier 3 |

#### `raxol_agent_client_protocol`

No event is added or renamed here by this spike. Classifications are the registry's
(`agent_client_protocol/telemetry.ex:47-106`). Measurements are `%{count: 1}` at every
`emit_telemetry/2` and `apply/3` site (`session.ex:1009`, `connection.ex:1559`,
`delivery.ex:82`, `reattach.ex:361`, `journal/writer.ex:496`) and `%{}` at the two
`attach_policy.ex` sites (`:241`, `:261`). Metadata is listed where it was read in this spike;
other rows' metadata was not re-read and is not claimed.

| Event | Metadata read | Class | Status |
| --- | --- | --- | --- |
| `[:raxol, :acp, :attach, :denied]` | `session_id`, `surface`, `reason` | operational | unchanged |
| `[:raxol, :acp, :attach, :granted]` | `session_id`, ... | operational | unchanged |
| `[:raxol, :acp, :delivery]` | `session`, `turn`, `decision`, `buffered`, `ordinal`; `delivered`, `expected` on `:fail` | operational | **changed**, tier 4b: add `session_id`/`turn_id` beside `session`/`turn` (additive), deprecate the old keys |
| `[:raxol, :acp, :dup_reply]` | -- | invariant | unchanged |
| `[:raxol, :acp, :duplicate_inflight_id]` | -- | peer | unchanged |
| `[:raxol, :acp, :empty_chunk_rejected]` | -- | operational | unchanged |
| `[:raxol, :acp, :handler_crash]` | -- | operational | unchanged |
| `[:raxol, :acp, :inbound_shed]` | -- | operational | unchanged |
| `[:raxol, :acp, :invalid_request_frame]` | -- | peer | unchanged |
| `[:raxol, :acp, :journal, :non_holder_turn_completed]` | `session_id`, `turn_id` | operational | unchanged |
| `[:raxol, :acp, :late_response]` | -- | peer | unchanged |
| `[:raxol, :acp, :malformed_response]` | -- | peer | unchanged |
| `[:raxol, :acp, :notification_shed]` | -- | operational | unchanged |
| `[:raxol, :acp, :parse_error]` | -- | peer | unchanged |
| `[:raxol, :acp, :session_idle_reaped]` | -- | operational | unchanged |
| `[:raxol, :acp, :unknown_notification]` | -- | peer | unchanged |
| `[:raxol, :acp, :zero_updates_turn]` | -- | invariant | unchanged |

### Answers to the open questions

1. **Where is a turn?** Four places, and only four boundaries are in-process synchronous
   (Gap 2). Instrument the two chokepoints (`complete/2`, `dispatch_tool_call/3`) and the two
   sync turn frames (`Turn.run/3`, `TurnRunner.start_turn/3`). `Stream.react/2` and
   `Code.App` are cross-process; the former gets no span, the latter gets a manual start/stop
   in tier 2b. Cost events are per **provider call** and share a `turn_id` across the rounds
   of one prompt (`Contract` mints it once per pump, `contract.ex:281`), and a sub-agent round
   inherits the running turn's id, so per-prompt cost is a sum over `turn_id` with nothing
   left out.
2. **Does converting counters to spans break a consumer?** In-repo, only `ThreadLogRouter`
   and eleven test pins; the design converts nothing, so nothing breaks. The two genuinely
   breaking changes are in tier 4 and carry migrations.
3. **Overhead?** 0.05-0.6 us per emit depending on handler count; ~0.5 us per span. Not a
   constraint on any proposed boundary ("Overhead, measured").
4. **Is `flag_unpriced` reachable unarmed?** The predicate is; the halt is not. Hence
   `:unpriced` with `armed?` plus a separate halt event.
5. **Should the money-path events carry dollars to Symphony's `BudgetCap`?** No. A telemetry
   handler runs fire-and-forget in the emitting process; a budget decision belongs in the data
   path. `BudgetCap` (`budget_cap.ex:84-90`, integer ETS counters, `cost_fn` typed
   `map() -> non_neg_integer()` at `:96`) should price the `usage` already in the forwarded
   `:turn_completed` payload (`runners/raxol_agent.ex:882-894`) through the now-public
   `LlmPrices.turn_cost/4`, scaled to micro-USD. Telemetry observes that seam; it must never be
   it.
6. **Does anything need OpenTelemetry?** Not in a library package. `:telemetry` plus a
   `Telemetry.Metrics` definition list (`Raxol.Agent.Telemetry.metrics/0`, using the root's
   existing `telemetry_metrics` dep) is the right export surface; a host wires a reporter. The
   bridge from `:telemetry` to `Raxol.Core.Metrics.Cloud`'s OTLP sender is this repo's job if
   this repo wants SigNoz to see agent events, and it is one handler module, not an SDK
   dependency. Not built here.
7. **Which log-only conditions are invariants?** Predicted 2 (named `emit_bridge`,
   `tool_converter`); found 2 candidates (`session.ex:351`, `:383`); demoted both on strict
   reading; **0 of 34**.

### Estimate and sequence

| Tier | Files | Public-contract risk | Migration | Sequence |
| --- | --- | --- | --- | --- |
| 1 (done) | `llm_prices.ex`, `code/app.ex`, `agent/telemetry.ex`, `native_harness.ex` (prose), 2 test files; 5 events incl. `halt.ledger_unreachable` | none: additive function, additive events | none | shipped in this change |
| 1 remainder | `code/app.ex` (`:refused`), `turn_runner.ex` + `client_protocol/budget.ex` (ACP budget events), 4 registry rows, 2 test files | none | none | second |
| 4a (PII, done) | `policy_applier.ex`, `thread_log_router.ex`, `policy.ex`, Symphony `runners/raxol_agent.ex`, CHANGELOG, 3 test files | **breaking**: `metadata.params` removed | none; clean cutover, named in CHANGELOG Security | shipped in this change |
| 5 | `policy_applier.ex`, `agent/telemetry.ex`, `telemetry_registry_test.exs`, `test/support/invariant_sentinel.ex` (delete), `raxol_core/.../invariants.ex` (scanner shapes) or 4 ACP sites | none for consumers; internal test-infra change | none | third, before tier 2 adds twelve rows to a regex-checked registry |
| 2a | `http.ex`, `tool_converter.ex`, `turn.ex`, `turn_runner.ex`, 12 registry rows, 4 test files | none (additive) | none | fourth |
| 3 | `scheduler.ex`, `emit_bridge.ex`, `tool_converter.ex`, `session.ex`, 8 registry rows, 4 test files | none (additive) | none | fifth; scheduler first within it |
| 4b | `journal/*`, `sandbox_hook.ex`, `hook.ex`, `turn_runner.ex`, ACP `delivery.ex` + `connection.ex`, registry comments, CHANGELOG | **breaking** for `wall_ms`; additive otherwise | one-release dual emission for `wall_ms` | sixth |
| 2b | `code/app.ex` (model fields, three exits), 2 registry rows, `app_*_test.exs` | none | none | last; highest defect risk (leaked spans) |
| bridge (OQ6) | new `Raxol.Agent.Telemetry.Metrics` + one handler into `Metrics.Cloud`, host wiring | none | none | after 2a, when there is latency to export |

Not scoped: the ACP package's own turn/session telemetry beyond the correlation keys; Symphony's
`turn_count` fix (a runner change, not telemetry); `Raxol.Core.Telemetry.TraceContext`, which
carries ids in the process dictionary without spans, durations or `:telemetry` (`trace_context.ex:29-34`,
`:74-233`) and is a separate design question; `web/` dashboards.

### Do not do this

- **Do not make any event on the turn path `:invariant` because its body "should be total".**
  Every candidate wraps user code or I/O (`http.ex:52`, `dynamic.ex:30`, `tool_converter.ex:96`).
  The terminal precedent does not transfer; a false invariant gets the mechanism deleted.
- **Do not put a discriminator in a name that a consumer would want to enumerate.** The five
  policy members are subscribable only because someone wrote them down twice; `scan_lib!`
  cannot see them. Static names, varying part in metadata.
- **Do not put `prompt`, tool `args`, `target` chat ids, or file paths into metadata as though
  they were labels, and do not put the wrapped argument there at all.** The applier did
  (`params`) and the router persisted it; both are fixed here, and the fix is enforced rather
  than documented: `apply/4` refuses non-identifier `metadata:` values and the router mirrors
  only allowlisted correlation keys. A future emitter that wants to persist something new
  through the router names the key in `attach/4` and it must still be an identifier.
- **Do not emit `:unpriced` (or anything) for a call that reported no usage and no price.** It
  fires on every ollama turn and pages nobody usefully. The blind spot is real and belongs in
  ADR-0035's fallback discussion, not in a noisy event.
- **Do not wrap `Stream.react/2` in a span.** It returns a lazy stream; the span measures
  microseconds (`stream.ex:164`, `:231`).
- **Do not wrap `ToolExecutor.run_one/2`.** `gated_run/4` blocks on a human (`tool_executor.ex:465`).
- **Do not use a telemetry handler to make a budget decision.** Handlers are fire-and-forget
  and run in the emitter (OQ5). `BudgetCap` prices in the data path or not at all.
- **Do not convert an existing counter's shape in place** unless it is a leak. `wall_ms` is a
  shape change that waits for a dual-emission release and a CHANGELOG entry; `params`,
  verbatim `reason`/`key`, and the shell command in `sandbox.denied` were leaks and were cut
  over in one change, each named under Security.
- **Do not persist an unkeyed hash of an argument, and do not promise it joins across runs.**
  `Telemetry.digest/1` is keyed per VM run on purpose: an unkeyed truncated hash of a
  low-entropy argument is a confirmation oracle, and external term format is not a canonical
  encoding. If a cross-run join is ever wanted, that is a canonical encoding plus a persisted
  key, which is a different design with a different threat model.
- **Do not emit a value you did not build without `Telemetry.bound/1`.** Error reasons and
  user-derived keys are how content arrives in metadata by accident. The router bounds every
  payload as a backstop, but a Logger or metrics handler sees the raw event.
- **Do not add `{:telemetry, ...}` to `raxol_agent/mix.exs`.** It loads transitively
  (`mix run -e 'IO.inspect(Code.ensure_loaded?(:telemetry))'` prints `true`, 1.4.2 via
  `raxol_core/mix.exs:36`), and a lockfile change fails `mix deps.get --check-locked` in CI.
- **Do not prove an event fires by reasoning from the emit site.** `[:raxol, :acp,
  :zero_updates_turn]` was dead code behind a guard a test shim satisfied. Attach a real
  handler in a suite where the guard is genuinely true. The over-limit halt in this change is
  proven from `raxol_payments`' suite for exactly this reason: in `raxol_agent`'s own suite the
  Ledger module is absent (`cost_ledger_test.exs:6-8`) and the site is unreachable.
- **Do not trust a regex completeness test.** It accepted a comment as an emit
  (`telemetry_registry_test.exs:21-23`).
- **Do not trust `scan_lib!/1` on a package that emits through `apply/3`.** It misses four ACP
  events today.

## Alternatives considered

**One `[:raxol, :agent, :cost]` event with `outcome: :priced | :unpriced | :halted`.** Fewer
rows, one metric with a label. Rejected: it multiplexes the happy path with two failures under
one name, which is the exact shape that left `raxol_earn` with no expressible invariant. None
of these is an invariant today, but the rule exists so that a future one can be.

**One `[:raxol, :agent, :budget, :halted]` with `reason: :unpriced | :over_limit`.** Both
members are failures, both `:operational`, so enforcement loses nothing. Rejected on remedy:
an unpriced halt wants a price row or env rate; an over-limit halt wants a policy decision or
an unfreeze. Two names cost one registry row and make the alert text write itself.

**Return `source` from `turn_cost_usd/4` by widening its tuple.** Rejected: 13 callers in one
test file and one in `app.ex` would change, and a new function that the old one delegates to
is strictly additive. `turn_cost_usd/4` stays for callers that want a number.

**Emit through a `Raxol.Agent.Code.CostTelemetry` module.** Rejected: the repo's shape is a
literal at the site (`writer.ex:544`, `hook.ex:274`, `turn_runner.ex:982`), which is what both
the regex test and `scan_lib!/1` read. A helper would need to be named `emit_telemetry` to be
scanned, and that is a convention, not a module.

**Manual `:start`/`:stop` around `Code.App`'s turn now.** It is the user-facing turn on the
coding surface and the one operators most want timed. Deferred to tier 2b because it needs two
model fields and three exit sites, and a leaked span from a missed exit is a worse signal than
none; the four sync spans should establish the shape first.

**An OpenTelemetry SDK dependency.** Rejected for a Hex library: it forces an exporter on every
host, and the repo already has `telemetry_metrics` at the root and an OTLP sender in
`Metrics.Cloud`. A `Telemetry.Metrics` definition list is the library-appropriate surface.

**Promote all 34 log sites.** Rejected: 26 are "an injected function raised" at a seam the user
owns or a filesystem condition with a higher-level signal. Eight events is the set a consumer
can act on; the rest can be promoted when someone asks.

**Meter tokens instead of dollars in the events.** Tokens are already in the measurements. The
`cost_usd` measurement is what the ledger records and what the halt keys on; omitting it would
make the event unable to answer "what did this session spend", which is the question.

## Consequences

### What becomes possible

The resolution order of ADR-0035 is observable per call: a `source` distribution shifting from
`:reported` to `:flat_table` on one backend is a mispricing in progress, visible before a
budget notices. An unpriced turn is visible in the single-user configuration that gets no
halt. A halt is a countable event joined to its session and turn. `LlmPrices.turn_cost/4` is
public, which is what Symphony's `BudgetCap` needs to price in dollars (OQ5).

Tiers 2-5 have a committed shape, a file list, a risk rating and an order, with the two
breaking changes named and each carrying a migration.

### What costs we accept

`Code.App`'s fold grows by four emit sites, `meter_usage/5` and `enforce_budget/2` gain an
argument, and the module already runs 3,400 lines. The events are five-segment names in a
registry whose other rows are four; the precedent is `journal.checkpoint.surrogate`.

The over-limit halt's proof lives in another package's suite. That is the correct home
(`code_llm_ledger_test.exs:2-5` says why) and it means a change to the event's shape must be
run against `raxol_payments` too.

Every proposed span nests, so a naive consumer summing all `[:raxol, :agent, *, :stop]`
durations triple-counts. The catalog says so; a dashboard template would say so louder.

### What this ADR does not decide

- Whether `after_turn/4` is inside the library-turn span.
- Whether the ACP turn is spanned at the runner or the Session; it recommends the runner.
- The dashboard and alert definitions for SigNoz. The observability-designer shape is:
  SLI "unpriced share" = `unpriced / (priced + unpriced)` per backend, SLO 0 over 24h, alert on
  any non-zero; SLI "halts" per session, alert on any; latency p99 per backend once tier 2a
  lands. Those are one PR each once the events exist.
- Whether `session.emit_bridge_crashed` is ever promoted to `:invariant`. The procedure is
  stated; the verdict waits for data.

## Validation

The tests this change produced, with the runs that produced them.

- **Every tier-1 event fires through a real `:telemetry.attach_many/4` handler.**
  `packages/raxol_agent/test/raxol/agent/code/app_metering_test.exs`, "cost telemetry"
  describe block, 7 tests: flat-table `:priced` with `source: :flat_table`, `cost_usd` within
  1e-9 of 0.0035, and `session_id == model.session_key`, `turn_id == "t1"`; `:reported`
  attribution; `:env` attribution; `:unpriced` with `armed?: false` and no halt; `:unpriced`
  with `armed?: true` followed by `budget.halt.unpriced`; `:llm_subagent` kind with
  `turn_id: nil`; and nothing at all for `usage: %{}` on an unpriced model.
  `packages/raxol_payments/test/raxol/payments/code_llm_ledger_test.exs`, "an over-limit halt
  emits its event with the ledger's limit": `:priced` with `ledger?: true` then
  `budget.halt.over_limit` with `limit: :session`, against a real `Raxol.Payments.Ledger`.
- **Every existing pricing assertion unchanged.** `llm_prices_turn_cost_test.exs` and
  `llm_prices_test.exs` run untouched and pass, which is the check that `turn_cost_usd/4`'s
  delegation kept its numbers.
- **The registry is complete.** `telemetry_registry_test.exs` passes with the five new rows;
  the `scan_lib!` versus `events/0` diff shows the only registry-minus-scan residue is the five
  runtime-built policy members, and scan-minus-registry is empty.
- **Runs, as of the last revision.** `cd packages/raxol_agent && mix test
  test/raxol/agent/policy_applier_test.exs test/raxol/agent/thread_log_router_test.exs
  test/raxol/agent/telemetry_registry_test.exs test/raxol/agent/sandbox_hook_test.exs
  test/raxol/agent/code/app_metering_test.exs test/raxol/agent/llm_prices_turn_cost_test.exs
  test/raxol/agent/llm_prices_test.exs test/raxol/agent/code/cost_ledger_test.exs` ->
  `99 passed`. `cd packages/raxol_payments && mix test
  test/raxol/payments/code_llm_ledger_test.exs` -> `12 passed`. `cd packages/raxol_symphony &&
  mix test test/raxol/symphony/runners/raxol_agent_policy_test.exs` -> `4 passed`.
  `mix compile --warnings-as-errors` clean in all three packages.

The tests a tier-2 through tier-5 implementation must produce:

- **Each span fires `:start` and `:stop` with a positive `duration`** through a real handler, and
  `:exception` fires when the wrapped user code raises, in a test that injects the raise.
- **Nesting is asserted, not assumed:** one `Turn.run/3` with a two-round mock backend yields
  exactly one turn span, two backend spans and the tool spans of the tool round.
- **Each promoted log condition fires its event from the same clause as its log line**, in the
  test that already drives the log (`scheduler_test.exs:364-386` for the thread-log arm;
  `identity_invariants_test.exs:293` for the durable drop; `hook_test.exs:435` for the invalid
  return).
- **A metadata-core test** reads every registered event's emit site and fails if `session_id`
  is absent where a session is in scope.
- **The `wall_ms` migration** has a test asserting dual emission during the deprecation release
  and a test asserting removal after it. (`params` did not get a migration: it was a leak. Its
  tests are `policy_applier_test.exs` "the wrapped argument never reaches metadata" and
  `thread_log_router_test.exs` "nothing persisted carries the wrapped argument", both driving a
  marker string through the applier and asserting it is absent from every emitted and persisted
  map while the digest is present and joins the events. The enforcement has its own:
  `policy_applier_test.exs` "refuses anything that is not an identifier, without echoing it"
  drives a long binary, a map, a list, a struct and a non-atom key through `metadata:` and
  asserts each raises with a message free of the marker; `thread_log_router_test.exs`
  "persisted metadata" asserts the mirror is exactly the core plus host-named keys, that an
  unnamed key is dropped, and that a listed key with a non-identifier value is dropped while the
  handler stays attached for the next event. The bounding and scrubbing have theirs:
  `policy_applier_test.exs` "key and reason are bounded" drives a content-bearing key and a
  `{:http_error, 500, body}` reason and asserts both arrive as `{:redacted, :binary, n}` leaves
  under an intact shape, with one digest shared by all four events of the call;
  `sandbox_hook_test.exs` "the emitted reason names the program, never the arguments" denies a
  `curl` carrying a bearer token and asserts the wire reason is `{:shell_denied, _, "curl"}` with
  a digest and no token, while the caller's `{:deny, reason}` still carries the command;
  `thread_log_router_test.exs` "a payload from an emitter that forgot to bound is bounded here"
  drives a raw execute with a long command and asserts the persisted payload is bounded;
  `app_metering_test.exs` "a sub-agent round ... under the running turn's id" asserts the
  inherited `turn_id` and `nil` when no turn runs; `code_llm_ledger_test.exs` "a ledger that
  dies mid-turn" stops a real ledger under a running turn and asserts
  `halt.ledger_unreachable` fires and `halt.over_limit` does not.)
- **`Raxol.Agent.Telemetry` under `scan_lib!/1`**: the five policy names appear as static keys
  and the regex test is deleted, with a vacuity guard that the scan found more than ten events.
- **`scan_lib!/1` finds the four ACP `apply/3` sites**, or those sites are normalized, before
  any ACP registry test depends on it.

## References

- ADR-0035: the metering semantics tier 1 observes; the resolution order and the fail-closed
  halt (PR #962, `docs/adr/0035-multi-rate-cost-metering.md`)
- ADR-0034: Symphony's token-proxy `BudgetCap` and the `merge_tokens/2` delta rule (OQ5)
- ADR-0030: the ACP `session/update` delivery contract that `[:raxol, :acp, :delivery]` observes
- ADR-0020: `Raxol.Agent.Sandbox`, the origin of `[:raxol, :agent, :sandbox, :denied]`
- `packages/raxol_core/lib/raxol/core/telemetry/invariants.ex:25-28` (criterion), `:85`
  (`@emit_functions`), `:389-406` (`scan_lib!/1`)
- `packages/raxol_core/lib/raxol/core/telemetry/invariant_sentinel.ex:42-52` (why `async: false`)
- `packages/raxol_agent/lib/raxol/agent/telemetry.ex`: the registry, four new rows
- `packages/raxol_agent/test/raxol/agent/telemetry_registry_test.exs:21-23`, `:36`: the regex
  test and its comment-counts-as-emit rule
- `packages/raxol_agent/lib/raxol/agent/llm_prices.ex`: `turn_cost/4` and `turn_cost_usd/4`
- `packages/raxol_agent/lib/raxol/agent/code/app.ex`: `record_turn_cost/2`, `meter_usage/5`,
  `emit_cost/4`, `flag_unpriced/4`, `enforce_budget/2`, `turn_cost/3`; the submit gate at
  `:775-777`; the cross-process turn at `:826`, `:871`, `:875`, `:1483`, `:1493`
- `packages/raxol_agent/lib/raxol/agent/code/cost_ledger.ex:33-34`: the positive-cost guard
- `packages/raxol_agent/lib/raxol/agent/policy_applier.ex`: the runtime-built name
  (`emit/3`), `params_digest`, and the `metadata:` option
- `packages/raxol_agent/lib/raxol/agent/thread_log_router.ex:38-60`, `:91`, `:112`: the only
  non-test consumer
- `packages/raxol_agent/lib/raxol/agent/scheduler.ex:243-337`, `:507`, `:595-602`: the
  fire path, the ten log sites, the injectable seams
- `packages/raxol_agent/lib/raxol/agent/emit_bridge.ex:259`, `:329-341`: the durable drop and
  its two reasons
- `packages/raxol_agent/lib/raxol/agent/session.ex:339-391`: the three crash sites
- `packages/raxol_agent/lib/raxol/agent/stream.ex:107-108`, `:164`, `:231`, `:449`, `:534`:
  the ReAct loop and its two chokepoint calls
- `packages/raxol_agent/lib/raxol/agent/backend/http.ex:47-68`, `:52`, `:788`: the provider
  call, the user plugins inside it, ollama's empty usage
- `packages/raxol_agent/lib/raxol/agent/action/tool_converter.ex:81`, `:96`, `:110`, `:196`
- `packages/raxol_agent/lib/raxol/agent/harness/tool_executor.ex:423`, `:465`, `:665`
- `packages/raxol_agent/lib/raxol/agent/turn.ex:44-69`
- `packages/raxol_agent/lib/raxol/agent/client_protocol/turn_runner.ex:339`, `:345`, `:351`,
  `:379`, `:603`
- `packages/raxol_agent/lib/raxol/agent/contract.ex:281`, `:464`, `:524`: `turn_id` minting and
  the per-round `:turn_completed`
- `packages/raxol_agent_client_protocol/lib/raxol/agent_client_protocol/telemetry.ex:47-106`
- `packages/raxol_agent_client_protocol/lib/raxol/agent_client_protocol/delivery.ex:81-82`,
  `ext/attach_policy.ex:239`, `:259`, `ext/reattach.ex:359`, `journal/writer.ex:494`: the
  four emit shapes `scan_lib!/1` misses
- `packages/raxol_agent_client_protocol/mix.exs:55`: `:telemetry` as a dev/test-only dep
- `packages/raxol_symphony/lib/raxol/symphony/orchestrator.ex:1974-1980`,
  `runners/raxol_agent.ex:882-894`, `sandboxes/budget_cap.ex:84-135`
- `packages/raxol_terminal/lib/raxol/terminal/telemetry.ex:62-78`: the invariant `:exception`
  leaves and why they earn it
- `lib/raxol/core/metrics/cloud.ex:57-75`, `:354`, `:376-378`, `:425-455`: the OTLP/SigNoz
  sender; `lib/raxol/core/metrics/metrics_collector.ex:83`: what feeds it
- `packages/raxol_earn/lib/raxol_earn/application.ex:32-33`: SigNoz export pending a collector
- `mix.exs:344-346`: root `telemetry`, `telemetry_metrics`, `telemetry_poller`
- The overhead microbenchmark was a throwaway script, not kept; its method and numbers are in
  "Overhead, measured"
