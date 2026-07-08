# ADR-0016: `raxol_acp` Job migration to `Raxol.Workflow`

## Status

**Superseded (2026-07-08)** by the seller-stack v1->v2 migration (Phases 1-4, #385/#390/#388/#389/#391). `Raxol.ACP.Job.Server`, `Raxol.ACP.Job.Workflow`, `Raxol.ACP.Job.StateMachine`, `Raxol.ACP.Job.Store`, and `Raxol.ACP.ContractClient` were all deleted; the v2 runtime is `Raxol.ACP.JobSession` + `Raxol.ACP.HookClient` -> `AgenticCommerceV3` (see `packages/raxol_acp/MIGRATION_V2.md`). The decision below is retained as historical record.

Proposed, 2026-06-16. Direct follow-up to ADR-0015 (Workflow Graph), which shipped the `Raxol.Workflow.*` primitive in Phase 25 and explicitly excluded the raxol_acp Job migration from its scope. This ADR makes that decision.

## Context

raxol_acp ships the first Elixir/OTP-native implementation of the Virtuals Agent Commerce Protocol. Each active job runs as a transient `Raxol.ACP.Job.Server` GenServer, registered under a unique-keys `Registry` (`Raxol.ACP.Job.Registry`) inside a `Raxol.ACP.Job.Supervisor` DynamicSupervisor. The server holds a state struct (`%{job_id, state, memos, config, persist?}`), validates each transition through `Raxol.ACP.Job.StateMachine` (a pure module), fires one `Raxol.ACP.ContractClient.create_memo` call per transition, and appends the resulting memo record to `Raxol.ACP.Job.Store` (ETS, optionally backed by DETS for cross-restart durability).

The state machine walks the canonical ACP phase ladder:

- `:request -> :negotiation -> :transaction -> :evaluation -> :completed`
- plus `:rejected` (terminal; seller declines from `:request`) and `:expired` (terminal; SLA breach from any non-terminal state)

Each non-terminal state has exactly one accepting event:

| State | Event | Next |
| --- | --- | --- |
| `:request` | `:accept_request` | `:negotiation` |
| `:request` | `:reject` | `:rejected` (terminal) |
| `:negotiation` | `:accept_payment` | `:transaction` |
| `:transaction` | `:deliver` | `:evaluation` |
| `:evaluation` | `:approve` | `:completed` (terminal) |
| any non-terminal | `:expire` | `:expired` (terminal) |

When `Job.Server` crashes mid-lifecycle, `:transient` restart spawns a fresh process and `init_manager/1` hydrates state + memos from `Store.load/1`. The transient-restart integration test in `packages/raxol_acp/test/raxol/acp/job/store_test.exs` is the oracle: kill the server with `:kill`, wait for the new pid via Registry, verify state and memo history.

This model works. The questions ADR-0016 has to answer are not "is the model broken" but "where does it bend under load that the new Workflow primitive can absorb cleanly". Three gaps in particular are observable today:

### Gap 1: broadcast-vs-persist race

The order of operations inside `do_transition/4` is `StateMachine.next/2 -> ContractClient.create_memo/5 -> Store.append_memo/3`. If the BEAM exits between `create_memo` returning `{:ok, tx_hash}` and `append_memo` committing, the memo is on-chain but the Store does not know it exists. On restart, hydration loads the prior memo set and the server believes it is one phase behind reality. The next inbound transition will re-fire `create_memo` for the same logical phase; the ACP contract's `nextPhase` validation will either reject the duplicate (failing the second transition) or treat it as a no-op (matching the chain's idempotency), depending on the contract version. State machine semantics stay correct, but visibility lags reality until the next successful round trip.

This is not a memo-loss bug: the on-chain record is authoritative. It is a visibility lag. The lag is bounded by the next caller-driven transition, which can be hours away in negotiation or evaluation phases.

### Gap 2: implicit "waiting" states

In `:negotiation`, the seller has accepted the request and is waiting for the buyer's payment authorization. In `:evaluation`, the seller has delivered and is waiting for the evaluator's approval. In `:transaction`, the seller is doing the work and the buyer is waiting on delivery. All three states are *waiting* on an event that originates outside the running BEAM.

Today, the wait is implicit. The `Job.Server` GenServer sits in its `:running` state with no message in flight, occupying a process slot and a memo history. There is no telemetry event that says "this job is paused, here's the reason, here's the expected resume condition". There is no enumerable "list of paused jobs" except by walking every running pid in the Registry and reading its state. Sellers building dashboards on top of this have to derive paused-ness from the absence of recent activity.

The `Raxol.Workflow` runtime has a primitive for exactly this shape: `Workflow.interrupt/1` returns control to the runtime with a typed reason, the run is paused, and `Compiled.resume/4` continues from the interrupting node when the external event arrives. Paused runs are queryable through the Saver. Telemetry emits `[:raxol, :workflow, :run, :interrupted]` with the reason in metadata.

### Gap 3: single-BEAM-node persistence

The current Store is a DETS file handle. ACP jobs that span days (cross-chain settlement, multi-day evaluation cycles) outlive any single BEAM process or container. Today, migrating an active job between deployments means manually shipping the DETS file. There is no built-in mechanism for one BEAM node to pick up where another left off.

Phase 25 shipped `Raxol.Workflow.Checkpoint.Saver.Postgrex` precisely for this case: multiple BEAM nodes pointing at the same Postgres database see each other's checkpoints. A job interrupted on node A can be resumed on node B via `Compiled.resume/4` against the shared Saver. No file shipping, no manual coordination.

### What Phase 25 already gave us

ADR-0015's runtime ships with the building blocks that close these gaps:

- `Raxol.Workflow.Checkpoint.Saver` behaviour with three adapters: `Ets` (volatile, fast), `Dets` (single-node durable), `Postgrex` (cross-node durable). The default choice can be configured per-graph.
- `failure_policy: :retry` with `max_attempts` and `retry_backoff_ms`. RPC transients (nonce fetch failures, receipt-wait timeouts) get retried automatically without `Job.Server` having to know about them.
- `failure_policy: :compensate` for saga-style rollback. ACP does not undo on-chain memos, but compensation could fire off-chain cleanup (e.g., notifying the buyer that a payment authorization is no longer needed).
- `Workflow.interrupt/1` and `Compiled.resume/4` for the waiting-phase pattern in Gap 2.
- Per-node CloudEvents telemetry with `causation_id` propagation. A run's full execution can be reconstructed from `[:raxol, :workflow, :*]` events.

Without Phase 25, this migration would be infrastructure work plus protocol work. With Phase 25, it is protocol work over an existing substrate.

## Decision

**Replace `Raxol.ACP.Job.Server`'s GenServer state machine with a Workflow-backed implementation behind a stable facade, in two phases.**

The public API (`Raxol.ACP.Job.transition/4`, `Raxol.ACP.Job.accept_request/1`, `Raxol.ACP.Job.deliver/1`, `Raxol.ACP.Job.approve/3`, `Raxol.ACP.Job.current_state/1`, `Raxol.ACP.Job.memos/1`) stays byte-identical. The implementation behind it becomes a `Raxol.Workflow.Compiled` graph backed by the configured Saver. External callers see no change.

### Phase A: shape-equivalent translation

Phase A is the executable scope of this ADR. The deliverable is a Workflow-backed `Job.Server` that passes the existing test suite without behavioral changes.

- New module `Raxol.ACP.Job.Workflow` compiles a graph mirroring the state machine. One `BehaviourNode` per non-terminal phase (`:request`, `:negotiation`, `:transaction`, `:evaluation`). Each node implements `Raxol.Workflow.Node` and wraps a single `ContractClient.create_memo` call.
- Edges use `add_conditional_edge` keyed on the transition event. The chooser function reads the current event off the state map and returns the destination node id. Terminal states (`:completed`, `:rejected`, `:expired`) become edges to `:__end__`.
- `failure_policy: :retry` with `max_attempts: 3`, `retry_backoff_ms: 200`. RPC failures during memo creation retry transparently; only after exhausting attempts does the workflow surface the error.
- `Job.Server` becomes a thin facade. It holds a `run_id` (mapped 1:1 to the ACP `job_id`), forwards transition events to `Compiled.resume/4`, and translates the workflow result tuples back into the legacy reply shapes:
  - `{:ok, _state, _meta}` -> transition advanced cleanly.
  - `{:interrupted, ^run_id, _state, value}` -> "waiting for X" (Phase B will leverage this; Phase A treats interrupt as a no-op).
  - `{:error, reason, _state}` -> propagate the error, leave the workflow in its prior checkpoint.
- Saver: `Saver.Dets` is the default (matches the current Store semantics exactly: file-backed, single-node, durable across restarts). `Saver.Postgrex` is opt-in via `Application.put_env(:raxol_acp, :job_saver, {Postgrex, %{conn: ..., table: ...}})`. The existing `Raxol.ACP.Job.Store` becomes a compatibility layer that delegates to the configured Saver; it can be deprecated after Phase A ships and direct callers migrate.
- The broadcast-vs-persist race from Gap 1 stays structurally the same. The `create_memo` call is a side-effecting node body. If it lands but the checkpoint write fails, the resumed run re-runs the node and the ACP contract's idempotency check is the backstop, exactly as today. No regression; no improvement either. This is honest; Phase A is parity, not enhancement.

### Phase B: leverage interrupts for waiting phases

Phase B is acknowledged here but warrants its own ADR because the interrupt shape involves the Seller protocol layer and has user-facing API consequences.

- Each waiting-phase node ends with `Workflow.interrupt(:awaiting_buyer_payment | :awaiting_evaluator_approval | :awaiting_delivery)` instead of returning `{:ok, _state}`.
- The corresponding `Job.transition/4` call routes through `Compiled.resume/4` with the inbound event payload as the resume value.
- The seller's "list paused jobs" view becomes a query against `Saver.list/3` filtered by jobs whose latest checkpoint metadata contains an `interrupt_reason`. Postgrex makes this a `WHERE` clause; Dets is a full scan but bounded.
- Phase B is a small change once Phase A is in place, but it changes the telemetry shape that consumer dashboards depend on (paused jobs surface as `:interrupted` events, not as the absence of activity). Defer until the Phase A facade has stabilized.

### Out of scope

- **Phase 24F.** Deleting the `Raxol.Core.Runtime.Command` struct is still gated on raxol_acp adopting Phase 24 `Directive`s for its on-chain operations (D-6). The Workflow migration in this ADR is independent: the node bodies call `ContractClient.create_memo` directly, not via a Directive. If D-6 lands first, the nodes can be re-implemented atop directives without changing the graph shape.
- **Cross-chain settlement workflows.** Xochi mandates live in `raxol_payments`. Whether they should become Workflow graphs is a separate question with different motivations (settlement is async, multi-party, and currently handled by a Mandate.Store GenServer).
- **TypedNode protocol for ACP-semantic nodes.** A future refinement might introduce `Raxol.ACP.Job.Node.CreateMemo` as a `TypedNode` struct implementing `Raxol.Workflow.Node.Executor`. Phase A deliberately uses `BehaviourNode` so the node code lives in the ACP module hierarchy and is easy to read alongside the StateMachine module. The TypedNode refactor is a polish pass after Phase A proves itself.
- **The DETS-to-Saver migration path for existing deployments.** Pre-alpha raxol_acp has no production deployments today, so we do not need a data migration tool. If that changes before Phase A ships, this ADR will need amendment.

## Consequences

### What becomes possible

- **Saver-backed cross-node resumability.** Postgrex Saver lets an ACP job interrupted on node A continue on node B. The seller's deployment is no longer one BEAM-node-wide.
- **Per-node telemetry and trace context.** Every transition emits `[:raxol, :workflow, :node, :*]` events through Phase 24's CloudEvents envelope. Causation IDs chain across the lifecycle. Existing `[:raxol_acp, :job, :*]` events can be emitted in parallel during a deprecation window.
- **Retry transparency.** RPC failures retry automatically without `Job.Server` knowing. Callers see one terminal `{:error, reason}` after `max_attempts`, not three.
- **Resume-on-restart collapses into one code path.** Today the `Job.Server.init_manager/1` hydration path and the `Compiled.resume/4` path are two implementations of the same idea. After Phase A, only `Compiled.resume/4` exists. One code path is easier to reason about, test, and audit.
- **Foundation for Phase B.** The waiting-phase interrupts in Phase B are a small change on top of the Phase A graph. Without Phase A, Phase B is a from-scratch redesign.

### What costs we accept

- **Phase A is ~500 LOC of new code in raxol_acp plus ~300 LOC of new tests.** The new code is `Raxol.ACP.Job.Workflow` plus the facade reshape of `Job.Server`. The new tests mirror the existing state-machine and Store integration tests against the Workflow-backed implementation.
- **Behavior parity verification is non-trivial.** The transient-restart hydration test in `store_test.exs` is the canonical oracle; any deviation in resume behavior must be deliberate, documented, and tested. Phase A's acceptance criterion is that the full `raxol_acp` test suite passes against the new implementation without rewriting the assertions.
- **Telemetry shape drift.** Workflow's per-node telemetry differs from the current `[:raxol_acp, :job, *]` events. Consumers of those events (dashboards, monitoring) will need updating. Mitigate by emitting both shapes during a deprecation window (one minor release at minimum) and documenting the new shape in the ACP README before deleting the legacy emission.
- **The Job.Store deprecation footprint.** Callers that read directly from `Raxol.ACP.Job.Store` (rather than through `Raxol.ACP.Job.*` accessors) will need to migrate. A grep for `Raxol.ACP.Job.Store.` in raxol_acp's own code shows the surface is small and contained; external callers are unknown but probably nil given pre-alpha status.

### What this ADR does not decide

- The Phase A implementation timeline. ADR is design-only; execution is a separate session and a separate PR (or a small series).
- The Phase B interrupt shape. Mentioned for context; full design lives in a future ADR.
- Whether `Raxol.ACP.Job.Store` is deleted or kept as a thin compatibility shim post-migration. Probably the latter for one release cycle, then deleted in a major version bump.
- The Saver Postgrex schema migration story for production deployments. raxol_acp is pre-alpha; if production adoption happens before Phase A ships, this ADR will need an amendment covering data migration.

## Alternatives considered

### Augment only: keep `Job.Server`, add a sidecar Workflow for new use cases

The idea: `Job.Server` stays as the canonical job lifecycle. A separate Workflow primitive becomes available for *new* multi-step flows that consumers want to build on top of ACP (e.g., subscription billing, multi-party escrow). The migration path is incremental: new flows use Workflow, old flows stay on `Job.Server`, and the two coexist.

Rejected. The migration cost is paid once either way. Doing it incrementally on top of a stable facade (the Replace decision) is cheaper than maintaining two substrates indefinitely. The augment approach also leaves the visibility-lag and waiting-state gaps unaddressed for the canonical flow, which is the flow most consumers use. The "let new use cases choose" framing is appealing until you realize the canonical flow is also a new use case for any new consumer.

### Workflow nested inside `Job.Server`

The idea: each `Job.Server` keeps its existing GenServer lifecycle but spawns a child Workflow process for the parts that benefit from it (the on-chain memo writes, the retry logic). `Job.Server` mediates between callers and the Workflow runtime.

Rejected. This doubles the process count per active job (one server + one workflow process), inherits the worst of both lifecycles (the GenServer's `:transient` restart semantics on top of the Workflow's `try/after` cleanup), and makes telemetry harder to correlate. The facade approach in the Replace decision achieves the same API stability without the structural overhead.

### Defer indefinitely

The idea: raxol_acp is pre-alpha; the current model works for canonical flows. Ship more features on top of it, revisit the migration when production usage actually demands it.

Rejected. The cost of the migration grows with adoption. Doing it now, before external callers depend on `Job.Server`'s internals (none currently do), is materially cheaper than doing it later. Phase 25's Workflow primitive is also genuinely better suited to ACP's lifecycle than the bespoke GenServer state machine; deferring means continuing to pay the cost of the visibility-lag and waiting-state gaps for no architectural benefit.

### New top-level package `raxol_acp_workflow`

The idea: introduce a third package alongside raxol_acp that adapts the Workflow primitive to ACP-specific concerns, leaving raxol_acp untouched.

Rejected by the same logic ADR-0015 used to keep Workflow itself in main raxol. raxol_acp already depends on raxol and the Workflow primitive is part of raxol. A separate package would be cargo-culted modularity: it imports the same dispatcher plumbing, the same Saver behaviour, the same Directive protocol, and adds zero isolation. The dep graph stays cleaner with the facade-replace approach inside raxol_acp.

### Use `gen_statem` per job instead of `Job.Server` + StateMachine

Considered, rejected. The current pure-module StateMachine + `Job.Server` GenServer pattern is more flexible than `gen_statem` because the state struct holds more than just the phase atom (it holds memo history, config, persistence flags). `gen_statem` would need a state struct in every callback anyway, at which point we are reinventing the GenServer with a more constrained protocol. The Workflow primitive sidesteps this entirely by treating the phase as a graph node, not as a state machine state.

### Use raw checkpoints without the Workflow runtime

Considered, rejected. The Saver behaviour is reusable on its own; one could imagine `Job.Server` writing checkpoints directly via `Saver.put/3` without the Workflow runtime. This addresses Gap 3 (cross-node persistence) but not Gap 2 (waiting-state explicitness). Half of the migration's value comes from the interrupt mechanism, which only exists inside the Workflow runtime. Adopting the Saver without the runtime is the worst of both worlds.

## Validation

How we know Phase A is done correctly:

- The full `MIX_ENV=test mix test` in `packages/raxol_acp/` passes against the new implementation without modifying any assertions in `store_test.exs`, `server_test.exs`, `state_machine_test.exs`, or the higher-level seller/buyer integration tests.
- The transient-restart hydration scenario (kill the server with `:kill`, wait for new pid, verify state + memo history) works identically.
- Both `Saver.Dets` and `Saver.Postgrex` integration tests pass against the new implementation (Postgrex tests gated on `RAXOL_WORKFLOW_PG_URL` or `POSTGRES_*` env vars per the pattern established in PR #296).
- The benchmark harness `mix raxol_acp.bench` produces results within ~10% of the current implementation. Workflow's per-attempt telemetry adds overhead; a 10% regression is acceptable for the visibility and resumability gains.

## References

- ADR-0015: Workflow Graph (the parent decision)
- ADR-0014: Telegram AI Guardian admin behaviour (the prior ADR; similar narrative style)
- `packages/raxol_acp/lib/raxol/acp/job/server.ex` (current `Job.Server`)
- `packages/raxol_acp/lib/raxol/acp/job/state_machine.ex` (current StateMachine)
- `packages/raxol_acp/lib/raxol/acp/job/store.ex` (current Store)
- `packages/raxol_acp/test/raxol/acp/job/store_test.exs` (the transient-restart test, the canonical Phase A oracle)
- `lib/raxol/workflow/runtime.ex` (Phase 25 runtime)
- `lib/raxol/workflow/checkpoint/saver/postgrex.ex` (Postgrex saver, PR #296)
