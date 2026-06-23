# ADR-0018: Operator-flow contract for paused runs

## Status

Proposed, 2026-06-16. Direct follow-up to ADR-0017 (paused-run query and pause-checkpoint contract). Codifies the cross-layer pattern that emerged when ADR-0017's runtime primitive was surfaced through six channels (Terminal, LiveView, MCP, Telegram, Watch, Orchestrator subscribers) in a single session.

## Context

ADR-0017 made paused runs first-class in the Workflow runtime: pause checkpoints with `interrupt_reason` metadata, the `c:list_paused/2` Saver callback, and `[:raxol, :workflow, :run, :paused | :resumed]` lifecycle telemetry. ADR-0016 Phase B added a `Job.Server.list_paused/0,1` facade on raxol_acp. The Symphony orchestrator's pause/resume machinery (`park_paused/4`, `dispatch_resumption/3`, `resume_run/3`) was wired but untested before this session and is now covered by lifecycle tests. The Codex runner converts `:approval_required` errors into `{:pause, :awaiting_approval, token}`. The Symphony MCP surface gained `symphony_list_paused` and `symphony_resume_run`. The Terminal, LiveView, Telegram, and Watch surfaces all render the paused set with the same `interrupt_reason` vocabulary and the same `sym:resume:<issue_id>:<decision>` callback shape.

That is six channels (eight if you count the Workflow `[:raxol, :workflow, :*]` telemetry stream and the per-run `{:command_result, ...}` message stream as separate consumers) that all converge on the same operator-flow vocabulary. The pattern is real, repeated, and works. It is not documented.

The cost of leaving it undocumented is concrete:

- A future surface author (Slack? Discord? web hooks for incident management? voice-driven SMS?) has to grep across `surfaces/` to derive the contract. If they get it wrong, every other channel diverges from theirs and the vocabulary fractures.
- The vocabulary itself (`:awaiting_X` where X names the *external party* the run is waiting on) is a convention that fell out of the four ACP `pause_reasons/0` atoms plus `Codex.pause_for_approval`'s `:awaiting_approval`. It is consistent but it is implicit. The next pause reason added will either match this convention or won't, and there's no document to push on.
- The callback shape (`sym:resume:<issue_id>:<decision>`) appears in three places (`Telegram.Formatter`, `Watch.Formatter`, `MCP.symphony_resume_run`'s description). They agree by coincidence right now. They could drift.
- The lifecycle event ordering (`:worker_paused` -> operator decision -> `:worker_resumed`; or at the run level `:interrupted` -> `:paused` -> `:resumed`) is real semantics that consumers can rely on. None of it is written down.

This ADR makes the cross-layer pattern explicit so the next consumer doesn't have to re-derive it from the code.

### Why this is not part of ADR-0017

ADR-0017 documents the Workflow runtime and Saver: the pause checkpoint, the `c:list_paused/2` callback, the resume semantics, the per-run telemetry. That is a runtime contract. This ADR documents the operator-facing contract that sits on top: the vocabulary, the callback shape, the channel obligations, the lifecycle event ordering. Two different audiences (runtime author vs. surface author) and two different review cycles (runtime changes are rare, surface additions are frequent). Splitting them keeps both ADRs focused.

## Decision

**Codify five things as the operator-flow contract.**

### 1. The `interrupt_reason` vocabulary

Pause reasons follow the pattern `:awaiting_<subject>` where `<subject>` names the *external party* the run is waiting on, not the action the run will take.

Canonical set today (from `Raxol.ACP.Job.Workflow.pause_reasons/0` plus the Symphony runners):

| Atom | External party | Source |
| --- | --- | --- |
| `:awaiting_request_response` | seller decides accept/reject | `Raxol.ACP.Job.Workflow` |
| `:awaiting_buyer_payment` | buyer authorizes payment | `Raxol.ACP.Job.Workflow` |
| `:awaiting_delivery` | seller delivers (buyer waits) | `Raxol.ACP.Job.Workflow` |
| `:awaiting_evaluator_approval` | evaluator approves the deliverable | `Raxol.ACP.Job.Workflow` |
| `:awaiting_approval` | operator approves Codex command/file change | `Raxol.Symphony.Runners.Codex` |
| `:awaiting_review` | operator/PR reviewer responds (Noop test runner uses this) | `Raxol.Symphony.Runners.Noop` |

Future additions must:

- Use the `:awaiting_<subject>` shape. Not `:waiting_for_X`, not `:blocked_on_X`, not `:needs_X`.
- Name the *party*, not the action: `:awaiting_ci`, not `:awaiting_ci_check`; `:awaiting_pr_merge`, not `:awaiting_merge`.
- Be atoms, not strings. Surfaces format them with `Atom.to_string/1` and apply `format_reason/1` for display.

The vocabulary is open: new pause reasons land as new atoms without any registry. Each runner is responsible for documenting which reasons it can emit (Codex emits `:awaiting_approval`; future runners will emit their own).

The Workflow runtime is reason-agnostic: it stores whatever atom the node passes to `Workflow.interrupt/1` in the pause checkpoint's `metadata.interrupt_reason` and surfaces it through `list_paused/2` and the `:paused`/`:resumed` telemetry. Surfaces filter and render on the atom.

### 2. The lifecycle event ordering

The pattern from a paused run's perspective:

```
external blocker hit          →  [:raxol, :workflow, :run, :interrupted]
pause checkpoint committed    →  [:raxol, :workflow, :run, :paused]
                                  Symphony.Orchestrator listener event :worker_paused
operator decision arrives     →  Orchestrator.resume_run(pid, issue_id, decision)
runner re-dispatched          →  Symphony.Orchestrator listener event :worker_resumed
                                  (Workflow [:run, :resumed] from ADR-0017)
runner re-enters with value   →  Workflow.interrupt/1 returns the resume value
                                  instead of throwing
```

Three contracts hold across this lifecycle:

- **`:interrupted` is synchronous**: it fires from inside the node's catch clause, before any durability is established. Consumers that only care about "a node returned an interrupt" subscribe here.
- **`:paused` is durable**: it fires after the pause checkpoint commits to the Saver. Consumers that care about durable pause state (dashboards, "list paused runs" views) subscribe here.
- **The operator decision is passed verbatim**: from the operator's input through `Orchestrator.resume_run/3`'s `resume_value` argument, through the worker's `:resume_value` opt, into the runner's `run/3` callback. The Workflow runtime does not interpret it; the runner does.

### 3. The callback shape

Operator-driven resume callbacks use the `sym:resume:<issue_id>:<decision>` namespace.

- `<issue_id>` is the tracker-internal issue id (the same id used by `symphony_get_run`, `symphony_stop_run`, etc).
- `<decision>` is `approved` or `rejected` by convention. Other strings are allowed but unrecognized values get forwarded verbatim to the runner; the runner decides whether to honor or reject them.

The shape is identical across Telegram (inline keyboard callback data) and Watch (notification action id). The MCP `symphony_resume_run` tool accepts a `decision` string argument that maps to the same value.

Other operator-action callbacks in the same `sym:` namespace:

| Callback | Effect |
| --- | --- |
| `sym:refresh` | Force an orchestrator tick |
| `sym:list` | Request the snapshot message (Telegram only) |
| `sym:stop:<issue_id>` | Terminate a running run |
| `sym:run:<issue_id>` | Request per-run detail (Telegram only) |
| `sym:approve:<issue_id>` | Pre-resume approval (legacy; see "Alternatives considered" for why this is being phased out in favor of `sym:resume:`) |
| `sym:dismiss` | Watch-only no-op (dismiss the notification) |

### 4. Channel obligations

A channel that renders Symphony state is obligated to render paused runs distinctly. The contract is *what*, not *how*:

- The header / summary line must include the paused count separately from the running and retrying counts. (`"running 2, paused 1, retrying 0"`, not bundled into "active".)
- The detail view must show, per paused entry: `issue_identifier`, `interrupt_reason` (via `format_reason/1` or equivalent), `paused_ms_ago`, and at least one of `last_event` or `last_message`.
- The action surface must offer an operator-driven resume path that emits a `sym:resume:<issue_id>:<decision>` callback. The channel may add other actions (Stop, Dismiss, Refresh) but Approve+Reject (or equivalent) for paused entries is required.
- The `empty_snapshot()` fallback (when the orchestrator is unreachable) must include `paused: []` and `counts.paused: 0` so the contract holds even under failure.

The six channels today and what they render for paused state:

| Channel | Paused-list surface | Paused-detail surface | Resume action |
| --- | --- | --- | --- |
| Terminal | `paused_panel/1` (yellow rows) | inline in panel | (none yet; via MCP) |
| LiveView | five-column `<section>` | inline in table | (none yet; via MCP) |
| MCP | `symphony_list_paused` | `symphony_get_run` (`{status: "paused"}`) | `symphony_resume_run` |
| Telegram | `paused_section/1` in snapshot | `paused_run_message/1` | inline keyboard buttons |
| Watch | snapshot body + badge | `paused_notification/1` | notification action ids |
| Orchestrator subscribers | `:worker_paused` event w/ snapshot | snapshot.paused list | (subscribers handle) |

### 5. The recipe for adding a new operator channel

A new surface (Slack, Discord, SMS, web hook, etc) implements the contract by:

1. Subscribing to `Orchestrator.subscribe/1` and handling `{:symphony_event, :worker_paused, snapshot}` for push notifications.
2. Implementing a `Formatter.snapshot_message/1`-equivalent that respects the four channel obligations above.
3. Reusing the `sym:resume:<issue_id>:<decision>` callback shape. A single bot router can dispatch callbacks across all channels because the shape is uniform.
4. Implementing the action handler by calling `Orchestrator.resume_run(orch, issue_id, decision)` with the verbatim `decision` string. Do not coerce or interpret.
5. For lifecycle observation (analytics, audit log), subscribe to `[:raxol, :workflow, :run, :paused | :resumed]` telemetry rather than reconstructing the lifecycle from snapshots.

A channel that wants to expose pause state programmatically (an HTTP API, a queryable index, a GraphQL field) reads through `Orchestrator.snapshot/1`'s `:paused` field, or `Job.Server.list_paused/0,1` for ACP-specific runs, or `Saver.list_paused/2` for the underlying Workflow primitive.

## Consequences

### What becomes possible

- **New channels onboard without re-deriving the pattern.** A Slack or Discord author reads this ADR, builds a `Formatter`, and inherits the cross-channel callback shape for free.
- **Cross-channel resolution.** An operator can pause on Watch, switch to their desk, see the same paused run on the LiveView dashboard, and resume from Telegram on their phone, all without losing context, because the `interrupt_reason` vocabulary and the issue_id are uniform.
- **Cross-runner pause adoption.** A new runner (Anthropic-direct, OpenAI, a custom one) maps blocking operations to `{:pause, :awaiting_<subject>, token}` and gets channel surfacing for free. No surface-side changes needed.
- **Analytics and audit.** Subscribing to `[:raxol, :workflow, :run, :paused | :resumed]` gives durable lifecycle data with `causation_id` chaining (per Phase 24). "How long was this paused before resolution?" becomes a metric.
- **MCP-driven incident response.** Operators (or other agents) can write tools that walk paused runs and apply policies (auto-approve known-safe commands, escalate unknown ones to humans). The `interrupt_reason` vocabulary is the policy surface.

### What costs we accept

- **The vocabulary is open.** New pause reasons land as new atoms with no registry, which means a typo (`:awating_review` vs `:awaiting_review`) ships and the offending runner emits an atom no surface filters on. Mitigation: each runner module documents its emitted atoms in the moduledoc; channel formatters' `format_reason/1` fallback prints the atom verbatim so the bug is visible.
- **The callback shape is convention, not enforcement.** A surface author who ignores the `sym:resume:<issue_id>:<decision>` shape and rolls their own breaks cross-channel resolution. Mitigation: the ADR's "recipe" section makes the shape explicit and the three existing surfaces' code is the reference.
- **The lifecycle event ordering is a soft contract.** The Workflow runtime *can* emit `:paused` without a preceding `:interrupted` if a future runtime change writes the pause checkpoint outside the node-catch path. Today the ordering holds because there's one code path; future changes must preserve it explicitly.
- **Channel obligations are minimum bars.** A channel that shows only a paused count without per-entry details satisfies the letter but defeats the operator-flow purpose. Mitigation: the contract is what to show, not how, so implementing reviewers can apply judgment.
- **The `sym:approve:<issue_id>` legacy callback survives.** Used by `run_notification/1` in the Watch formatter for non-paused runs (the "Human Review" pattern), not for paused runs. Documented as legacy; phasing out tracked separately.

### What this ADR does not decide

- **The Workflow runtime mechanics**. Pause checkpoints, the `c:list_paused/2` Saver callback, resume semantics: all in ADR-0017. This ADR sits on top.
- **The Symphony Orchestrator's internal pause map shape**. `Orchestrator.State.paused: %{}` is an implementation detail. The contract is what the snapshot exposes externally.
- **The runner protocol's pause shape**. `{:pause, reason, token}` is documented in `Raxol.Symphony.Runner` (`@type result`). Changes there are out of scope.
- **The PausedSaver Postgrex schema**. The Symphony PausedSaver is parallel work to ADR-0017's Workflow Saver; it persists Symphony's `:paused` map separately. The two pause-persistence stories (Workflow Saver for raxol_acp Jobs, PausedSaver for Symphony Orchestrator) coexist intentionally because they live at different abstraction levels.
- **Authentication / authorization for resume callbacks**. Who is allowed to call `symphony_resume_run` or click an Approve button is out of scope; the contract assumes the channel has already authenticated the operator.
- **Idempotency of resume callbacks**. Clicking Approve twice should not double-resume, but the de-duplication strategy (`Orchestrator.resume_run/3` returning `{:error, :not_paused}` on the second call) is implementation, not contract.

## Alternatives considered

### A registry of pause reasons

Maintain `Raxol.PauseReasons` with a canonical list of allowed atoms; runners must register their atoms before emitting them.

Rejected. The vocabulary's value is the convention, not the enforcement. A registry adds a coordination point for every new pause reason and doesn't catch the failure mode that matters (typos, divergent rendering). The open-set model with a documented convention costs less and degrades more gracefully.

### A typed `PauseReason` struct

Replace the atom with `%PauseReason{name: atom(), party: atom(), severity: atom()}` so surfaces can render structured fields rather than calling `Atom.to_string/1`.

Rejected. The struct buys nothing the channel formatters' existing `format_reason/1` helpers don't already do. Severity is a surface decision (Watch wants `:high` priority on `:worker_paused`, LiveView doesn't care). Party is implicit in the atom name and varies: `:awaiting_ci` waits on a system, `:awaiting_human_approval` waits on a person; a single `:party` field flattens that distinction. The atom carries the information; the struct just hides it.

### A different callback namespace per channel

Telegram callbacks could use `tg:resume:...` and Watch use `watch:resume:...` so a router can disambiguate by prefix.

Rejected. The whole point of the `sym:resume:` shape is that one router can handle all channels uniformly. The current convention works because the channel is identifiable from *which* socket/connection the callback arrived on, not from the callback string itself. Channel-prefixed namespaces would create per-channel routing tables for no behavior gain.

### Codify the contract in the moduledoc of each channel

Put the contract in `Telegram.Formatter`'s moduledoc, `Watch.Formatter`'s moduledoc, `MCP.symphony_list_paused`'s description, etc. Skip the ADR.

Rejected. Moduledocs are great for module-local contracts but cross-layer patterns disappear into them. The pattern *between* channels (the convergence on a shared vocabulary and a shared callback shape) is exactly the thing an ADR is for. Future surface authors will read the existing moduledocs *plus* the ADR; the ADR is the single source.

### Defer until a third runner is needed

Wait for a third runner (after Codex and RaxolAgent) to need `{:pause, _, _}` semantics; codify the pattern then.

Rejected. The pattern is already across six surfaces; the design memory is freshest right now. Codifying after another channel ships means re-deriving the convention from one more codepath. Cheaper to write now.

## Validation

How we know the contract is right:

- **The six channels in scope today all comply.** Each channel's formatter / tool / surface renders the four obligations (separate paused count, per-entry details, resume action, fallback empty shape).
- **The `sym:resume:` callback round-trips end-to-end.** An operator clicking Approve on Telegram triggers `Orchestrator.resume_run/3` with `decision = "approved"`, which becomes the runner's `resume_value` opt, which the Codex runner emits as a `:resumed` event with `payload.decision = :approved`. Telegram, Watch, and MCP all use the same shape.
- **The `interrupt_reason` vocabulary scales without registry.** The Codex runner's `:awaiting_approval` was added in the same session as the four ACP `:awaiting_*` reasons without any cross-coordination. Both render correctly on every channel because the channel formatters' `format_reason/1` fallback prints the atom verbatim.
- **A new channel author can build a Formatter in under a session by reading the existing two (Telegram + Watch) and following the recipe.** Tested against intuition; will be validated empirically when the next surface lands.

## References

- ADR-0015: Workflow Graph (the runtime foundation)
- ADR-0016: raxol_acp Job migration to Raxol.Workflow (the first runtime consumer)
- ADR-0017: paused-run query and pause-checkpoint contract (the runtime-level pause primitive)
- ADR-0012: MCP as Rendering Target (the precedent for cross-channel uniformity via the model-as-resource pattern)
- ADR-0013: Event-dispatch Backpressure (the precedent for run-event message semantics)
- `lib/raxol/workflow/runtime.ex` (pause checkpoint write + `:paused`/`:resumed` telemetry)
- `packages/raxol_acp/lib/raxol/acp/job/workflow.ex` (`pause_reasons/0`)
- `packages/raxol_symphony/lib/raxol/symphony/orchestrator.ex` (`park_paused/4`, `dispatch_resumption/3`, `resume_run/3`)
- `packages/raxol_symphony/lib/raxol/symphony/runners/codex.ex` (`pause_for_approval/3`)
- `packages/raxol_symphony/lib/raxol/symphony/surfaces/{terminal,web/dashboard_live,mcp,telegram/formatter,watch/formatter}.ex` (the six channels)
- Commits `91532c0f`, `a3e49326`, `fc06fca0`, `f56ee447`, `a038698d`, `3a93da96`, `c7347b4e` (the operator-flow contract in code).
