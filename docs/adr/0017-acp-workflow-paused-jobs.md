# ADR-0017: Workflow paused-run query and pause-checkpoint contract

## Status

**Superseded (2026-07-08)** by the seller-stack v1->v2 migration: the `Raxol.ACP.Job.Server` `:via_workflow` path this ADR extends was deleted in Phases 3-4 (#389/#391). The v2 `Raxol.ACP.JobSession` model handles pause/resume through its status + the `[:raxol, :acp, :job_session, :transition]` telemetry event, which `raxol_symphony`'s `Resumer` consumes. Retained as historical record.

Proposed, 2026-06-16. Direct follow-up to ADR-0016 Phase B. ADR-0015 (Workflow Graph) and ADR-0016 (raxol_acp Job migration) are the load-bearing priors. The same PR series that ships this ADR also flips `Raxol.ACP.Job.Server`'s `:via_workflow` default to `true` and introduces a per-process ephemeral Saver for `persist?: false`; both changes follow from the contract proposed here.

## Context

ADR-0016 Phase A shipped a Workflow-backed implementation of the ACP Job lifecycle behind a `via_workflow: true` opt-in. The four `:wait_*` nodes call `Workflow.interrupt/1` with phase-typed atoms (`:awaiting_request_response`, `:awaiting_payment`, `:awaiting_delivery`, `:awaiting_approval`). Phase A explicitly deferred two cross-cutting concerns to Phase B:

- **Paused jobs are not enumerable.** `[:raxol, :workflow, :run, :interrupted]` telemetry carries the reason, but consumers building dashboards must capture every event and maintain their own index. The Saver behaviour has no cross-thread query primitive; `list/3` is per-thread.
- **The runtime writes no checkpoint for the interrupting node.** When a node throws `{:__workflow_interrupt__, value}`, the runtime emits `[:raxol, :workflow, :run, :interrupted]` and returns `{:interrupted, run_id, state, value}` to the caller (`lib/raxol/workflow/runtime.ex:502-516`). The latest checkpoint remains the *previous* successful node (`test/raxol/workflow/resume_test.exs:55` was the oracle for this invariant). Paused-ness is not derivable from Saver state.

A seller building a "list active offers, here is what each one is waiting on" view today has to subscribe to telemetry, build an in-memory thread index, and reconcile that index against process death. The ACP semantic ("this job is paused, waiting for the buyer's signature") is real, durable, and cross-node, but the substrate to express it queryably does not exist.

ADR-0016 Phase B sketched a one-paragraph solution: "the seller's 'list paused jobs' view becomes a query against `Saver.list/3` filtered by jobs whose latest checkpoint metadata contains an `interrupt_reason`. Postgrex makes this a `WHERE` clause; Dets is a full scan but bounded." That sketch papered over three load-bearing details:

1. The runtime doesn't currently write the checkpoint the sketch wants to query.
2. `Saver.list/3` is per-thread and cannot enumerate across threads.
3. The `:interrupted` telemetry event is fired synchronously inside the node's catch clause, before any durability has been established. A consumer listening to `:interrupted` learns about an intent to pause, not a durable pause.

This ADR makes those details concrete and decides the contract.

### Why the work belongs in the Workflow runtime, not the ACP layer

raxol_acp could maintain its own ETS index of paused jobs, mirroring every transition into a side table. That would leave `Raxol.Workflow.*` untouched, and the same dashboard would work.

The problem with the local-index approach is that it splits the source of truth. A paused job is a Workflow concept: the runtime is the only thing that can definitively say "this node interrupted, this is the reason, the state is durably persisted." An ACP-local mirror is downstream of that fact and has to handle reconciliation when the workflow runtime sees something the mirror missed (a crash mid-write, a resume on a different node, a checkpoint replay). Every consumer that wants paused-job enumeration would need its own mirror; raxol_payments will want one, raxol_symphony already builds something analogous around runs. The substrate is the right level.

Phase 24's CloudEvents envelope and the Phase 25 Saver behaviour already give the runtime the tools. The cost is one additional checkpoint write per interrupt, one new optional Saver callback, and two new lifecycle telemetry events.

## Decision

**Three coordinated changes in the Workflow runtime, plus a public `Job.Server.list_paused/0,1` facade in raxol_acp.**

### 1. Pause checkpoint

When `execute_node_and_continue/6` catches `{:interrupt, value, state}` from `execute_node_once/4`, the runtime writes a checkpoint at the same step it would have used for a successful completion, with metadata extended to include the pause marker:

```elixir
metadata: %{
  node_id: current_id,
  run_id: run_id,
  graph_id: compiled.id,
  interrupt_reason: value,
  paused_at: DateTime.utc_now()
}
```

If no Saver is configured, the write is skipped (the helper returns `:no_saver`). The append-only contract on `Saver.put/3` is preserved: pause checkpoints are new rows at fresh `(thread_id, step)` keys, never overwrites.

### 2. Resume re-enters when `interrupt_reason` is set

`resume_with_checkpoint/5` inspects the loaded checkpoint's metadata. If `interrupt_reason` is present, the resume mode is `:reenter`; otherwise it stays `:traverse` (the pre-ADR-0017 behavior). `start_or_resume/7` branches on the mode: `:traverse` follows outgoing edges from the resume node (the node already ran successfully on the prior run), `:reenter` calls `step/6` on the resume node itself (the node interrupted; the seeded scratchpad value is what it needs to make progress).

The mode is a load-bearing semantic change. Before ADR-0017, the latest checkpoint was definitionally the last successfully-completed node, and resume traversed past it. After ADR-0017, the latest checkpoint *can be* the interrupting node, distinguished by the presence of `interrupt_reason`. Tests that pinned the "predecessor only" invariant (`resume_test.exs:47-55`, `checkpoint_integration_test.exs:104-123`, `async_resume_test.exs:52-67`) are updated to assert the new contract; the rest of the suite is untouched.

### 3. New `:paused` and `:resumed` lifecycle events

Two new telemetry events, both at the run level:

- `[:raxol, :workflow, :run, :paused]` fires inside `execute_node_and_continue/6` after the pause checkpoint commits. Metadata: `%{run_id, graph_id, node_id, interrupt_reason, paused_at, trace_context...}`. Suppressed when no Saver is configured (there is no durable pause to announce).
- `[:raxol, :workflow, :run, :resumed]` fires at the top of `resume_with_checkpoint/5` once the latest checkpoint has been loaded. Metadata: `%{run_id, graph_id, node_id, interrupt_reason, resume_mode, trace_context...}`.

The pre-existing `[:raxol, :workflow, :run, :interrupted]` continues to fire and gains an additional `interrupt_reason` key alongside the legacy `value` key. Consumers can migrate to `interrupt_reason` at their own pace; `value` is removed in the next breaking release.

The three events together describe the lifecycle of a paused run as a sequence: `:interrupted` (the node threw, no durability yet) -> `:paused` (the checkpoint committed) -> `:resumed` (the resume is starting, before the node re-executes). Existing consumers that only care about "a run paused" can continue listening to `:interrupted`; consumers that care about durability subscribe to `:paused`.

### 4. New Saver callback: `list_paused/2`

```elixir
@callback list_paused(config(), limit :: pos_integer()) :: {:ok, [paused()]}

@optional_callbacks list_paused: 2
```

`paused()` is a structured row:

```elixir
@type paused :: %{
  thread_id: thread_id(),
  interrupt_reason: any(),
  paused_at: DateTime.t() | nil,
  state: any(),
  metadata: map()
}
```

"Paused" is definitionally "the thread's latest checkpoint carries `:interrupt_reason` in metadata." Resuming a paused thread writes a follow-up checkpoint with no `:interrupt_reason`, which removes the thread from `list_paused` results. The resumption is implicit, not a separate `unpause` operation.

The callback is optional. The module-level `Saver.list_paused/2` helper dispatches to the adapter if `function_exported?/3` says yes, and otherwise returns `{:ok, []}`. Third-party Savers continue to compile and run; they just don't surface paused threads until they implement the callback.

The three in-tree adapters implement it directly:

- **Ets** scans the table once with `:ets.foldl/3`, keeps the highest-step checkpoint per `thread_id`, filters on `metadata.interrupt_reason`, sorts by `paused_at`, takes `limit`.
- **Dets** does the same scan inside a `handle_call`. Bounded but full-table; documented as a known cost.
- **Postgrex** adds `interrupt_reason text` and `paused_at timestamptz` columns plus a partial index `WHERE interrupt_reason IS NOT NULL`. The query is `SELECT DISTINCT ON (thread_id) ... ORDER BY thread_id, step DESC` collapsed inside a subquery, with `WHERE latest.interrupt_reason IS NOT NULL` as the outer filter. The `DISTINCT ON` is atomic; a concurrent resume that just committed a follow-up checkpoint is correctly excluded.

The canonical reason term still lives in the bytea metadata blob; the text column is a denormalized projection used only for `WHERE` filtering. Reads round-trip the term faithfully via `binary_to_term`.

### 5. Public facade: `Raxol.ACP.Job.Server.list_paused/0,1`

```elixir
@spec list_paused() :: [paused_job()]
@spec list_paused(keyword()) :: [paused_job()]

@type paused_job :: %{
  job_id: ContractClient.job_id(),
  interrupt_reason: atom(),
  paused_at: DateTime.t() | nil,
  state: StateMachine.state(),
  memos: [memo()]
}
```

Options: `:limit` (default 100) and `:reason` (filter by phase-typed atom, e.g. `:awaiting_buyer_payment`).

The facade reads the configured Saver via `configured_workflow_saver/0`, calls `WorkflowSaver.list_paused/2`, and translates each `paused()` row into a `paused_job()` by reading `current_state` and `memos` out of the pause checkpoint's `state` (the workflow runtime stores the full `Raxol.ACP.Job.Workflow.state()` map there). No N+1 calls; one Saver round-trip per dashboard render.

The function lives on `Job.Server` because that module is already the public facade per ADR-0016. The `Raxol.ACP.Job.*` namespace stays a namespace; no new callable `Raxol.ACP.Job` module is introduced.

### 6. Phase-typed reasons in raxol_acp

`Raxol.ACP.Job.Workflow` renames the two reasons whose waiter is ambiguous in the bare-event name: `:awaiting_payment` -> `:awaiting_buyer_payment` and `:awaiting_approval` -> `:awaiting_evaluator_approval`. `:awaiting_request_response` (seller decides) and `:awaiting_delivery` (both sides wait) stay unchanged.

A module-level `Raxol.ACP.Job.Workflow.pause_reasons/0` returns the canonical four atoms in phase-ladder order so dashboards can enumerate the expected reasons without scraping module source.

## Consequences

### What becomes possible

- **Queryable paused jobs.** `Raxol.ACP.Job.Server.list_paused/0` returns one row per in-flight ACP job and the canonical phase the job is waiting on. Seller dashboards stop needing a side index.
- **Cross-node visibility.** With `Saver.Postgrex` configured, two BEAM nodes sharing a database see the same paused jobs. The partial index keeps the query cheap regardless of how many completed jobs the table holds.
- **Resume from the interrupting node.** Today the workflow runtime can only resume by traversing past a successfully-completed checkpoint. After this ADR it can resume *into* an interrupting node, which is what `Workflow.interrupt/1`'s callers semantically need. The four ACP `:wait_*` nodes are the immediate beneficiary; future consumers (raxol_payments cross-chain settlement, raxol_symphony approval gates) get the same primitive.
- **Lifecycle observability.** `:paused` and `:resumed` events bracket the durable pause window. Telemetry consumers can compute "how long was this run paused" without needing process-level instrumentation.
- **Optional adoption.** The Saver callback is optional. Telemetry events are additive. The `interrupt_reason` lift on `:interrupted` is back-compat (the `value` key still ships). Consumers that don't subscribe to the new events see no behavioral change.

### What costs we accept

- **One extra checkpoint write per pause.** For ACP, that's at most four extra writes per job lifecycle (one per `:wait_*` node). Negligible against the on-chain `createMemo` cost that dominates each transition.
- **Semantic change to "latest checkpoint."** Three workflow tests pinned the pre-ADR invariant ("latest checkpoint is the predecessor of the interrupting node"). They are updated as part of the same PR; the contract is explicit and documented here. Future readers won't be misled.
- **Postgrex schema migration.** Two new nullable columns and a partial index. Pre-alpha deployments take the `ALTER TABLE` snippet documented in `Raxol.Workflow.Checkpoint.Saver.Postgrex`'s moduledoc; new deployments get the full schema from `create_table_sql/1`. No data backfill.
- **DETS `list_paused` is a full file scan.** Acceptable for the pre-alpha deployment count. Documented as a known limit; consumers expecting high paused-job counts should pick Postgrex.
- **`list_paused` only surfaces workflow-backed jobs.** Legacy-path ACP jobs (`do_transition_legacy`, surviving until Phase 24F lands) don't have interrupts, so they correctly don't appear. The default flip to `via_workflow: true` shipping in the same PR series narrows the legacy population.

### What this ADR supersedes

- **ADR-0016 section B's 3-reason list.** The prose said `:awaiting_buyer_payment | :awaiting_evaluator_approval | :awaiting_delivery`. The implemented contract is the four reasons in `Raxol.ACP.Job.Workflow.pause_reasons/0`: `:awaiting_request_response, :awaiting_buyer_payment, :awaiting_delivery, :awaiting_evaluator_approval`. The four-reason form is canonical; the three-reason prose was a sketch.
- **The implicit "latest checkpoint is the predecessor of the interrupting node" invariant.** After this ADR, the latest checkpoint of a paused run is the interrupting node itself, distinguished by `metadata.interrupt_reason`. Resume routes accordingly. The change is surgically scoped to checkpoints whose metadata carries the marker.
- **`:value` as the canonical metadata key on `:interrupted`.** Both `value` and `interrupt_reason` are emitted from this PR; `value` is removed in the next breaking release. Consumers should migrate to `interrupt_reason`.

## Alternatives considered

### ACP-local ETS index

Maintain a `Raxol.ACP.Job.PausedRegistry` ETS table inside raxol_acp, mirrored from every Job.Server transition. `list_paused/0` reads the registry. The Workflow runtime stays untouched.

Rejected. The mirror is downstream of the workflow runtime's view of paused-ness, and reconciling drift between the two sources of truth on crashes is exactly the kind of incidental complexity the Saver-as-SSoT model eliminates. The same dashboard would have to be rebuilt for every consumer that wants paused-run enumeration (raxol_payments has the same need for mandate-settlement gates; raxol_symphony already maintains analogous run state). Solving the problem once at the substrate level is cheaper than solving it once per consumer.

### Rewrite the predecessor checkpoint's metadata in place

When an interrupt fires, update the most recent successful checkpoint's metadata with the new `interrupt_reason` and `paused_at` keys. No new checkpoint, no resume semantics change.

Rejected. The append-only contract on `Saver.put/3` is documented (`saver.ex:16-22`) and consumers (including time-travel debugging and audit-log readers) depend on it. Breaking it for this one feature is a much bigger cost than the test updates required by the chosen approach. The `:erlang.term_to_binary/1`-backed metadata blob is also not easily mutated in place across all three adapters.

### Scan-by-telemetry only

Document that paused-job enumeration is the consumer's responsibility, achieved by subscribing to `[:raxol, :workflow, :run, :interrupted]` and `[:raxol, :workflow, :run, :resumed]` and maintaining a private index.

Rejected. Every consumer would rebuild the same index. Consumers that miss events during a restart (telemetry handlers re-attach but the events fired during the gap are gone) would have stale state with no way to reconcile. The Saver round-trip is the natural reconciliation primitive.

### New "thread_status" table in the Saver

Add `Saver.put_thread_status/3` and `Saver.list_threads_by_status/2` as a separate concern from checkpoints. Status is `{:paused, reason, ts}` or `:running`. Doesn't touch the checkpoint chain at all.

Rejected. It doubles the Saver's surface area for what is structurally the same data the checkpoint already carries (a row identified by thread, state attached). The cleanest read of the runtime is "checkpoints are the durable history; paused-ness is a property of the latest checkpoint." A side table would invite divergence over time as one path of the runtime writes to the chain and another to the side table.

### Defer until Phase 24F lands

Wait until the `Raxol.Core.Runtime.Command` struct is deleted and raxol_acp adopts Phase 24 Directives end-to-end, then revisit pause semantics.

Rejected. Phase 24F is gated on raxol_acp's Directive migration (D-6), which is its own multi-session effort. The paused-jobs dashboard is a near-term seller need; tying it to the Command-deletion timeline indefinitely defers a small, well-scoped improvement. The two are independent.

## Validation

How we know Phase B is done correctly:

- The full `MIX_ENV=test mix test test/raxol/workflow/` passes. The three pre-ADR oracles for "latest checkpoint = predecessor" (`resume_test.exs:47-55`, `checkpoint_integration_test.exs:104`, `async_resume_test.exs:52`) are updated to assert the new contract. All other assertions are untouched.
- The Ets and Dets `list_paused/2` round-trip tests pass: write 3 threads, pause 2 with distinct reasons, leave 1 running, list, assert exactly the 2 paused are returned with correct reason/timestamp ordering. Resume one, re-list, assert it disappears.
- The Postgrex SQL-shape tests pin `select_paused_sql/1`'s `DISTINCT ON` + outer filter pattern. The live-Postgres integration tests (gated on `RAXOL_WORKFLOW_PG_URL`) extend to round-trip the new columns.
- The runtime telemetry tests assert: `:paused` fires after the pause checkpoint commits, `:paused` is suppressed without a Saver, `:resumed` fires at the top of `resume/4` carrying the original `interrupt_reason`, `:interrupted` keeps firing and carries both `value` and `interrupt_reason`.
- The new `packages/raxol_acp/test/raxol/acp/job/server_paused_test.exs` exercises three concurrent jobs paused in three different phases, lists them, filters by `:reason`, resumes one to terminal state, re-lists, asserts it dropped.
- The Phase A oracle (`packages/raxol_acp/test/raxol/acp/job/store_test.exs` transient-restart hydration) continues to pass unchanged.

## References

- ADR-0015: Workflow Graph (Phase 25 runtime)
- ADR-0016: raxol_acp Job migration to Raxol.Workflow (Phase A delivered in PR #298)
- PR #296: Postgrex saver landing
- `lib/raxol/workflow/runtime.ex:502-516, 629-696` (interrupt catch and pause-checkpoint write)
- `lib/raxol/workflow/checkpoint/saver.ex:16-22` (append-only contract)
- `lib/raxol/workflow/checkpoint/saver/postgrex.ex` (schema, select_paused_sql/1)
- `packages/raxol_acp/lib/raxol/acp/job/workflow.ex` (canonical pause-reason atoms)
- `packages/raxol_acp/lib/raxol/acp/job/server.ex:220-281` (`list_paused/0,1` facade)
