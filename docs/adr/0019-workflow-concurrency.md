# ADR-0019: Workflow concurrency (`add_join/4` + `add_channel/4`)

## Status

Accepted, 2026-07-22 (implemented in `Raxol.Workflow.Graph` via `add_channel/3` + `add_join/4`). Originally proposed 2026-06-16. Direct follow-up to ADR-0015 (Workflow Graph), which shipped the sequential single-branch runtime and explicitly deferred joins and channels. ADR-0017 (pause checkpoints) and ADR-0018 (operator-flow contract) layered on top of the sequential runtime; this ADR adds the parallel branches without invalidating either. Pre-requisite for any future work (Phase 26, distributed Symphony, cross-chain settlement) that wants fan-out + reduce inside a single workflow graph.

## Context

`Raxol.Workflow` is single-branch sequential today. From `lib/raxol/workflow/runtime.ex:29-30`, verbatim:

> Joins (`add_join/4`) and channel reducers (`add_channel/4`) are still follow-ups: the runtime is single-branch sequential today.

The deferral is intentional. ADR-0015 prioritized a working runtime with checkpoints, interrupts, retry, compensate, and Postgrex durability over a richer execution model. Phase 25 shipped four months of capability inside that constraint; the deferred concurrency primitive is now the natural next chunk because every consumer that's piled on top of the runtime has the same shape:

- **raxol_acp** Job.Workflow is a 10-node graph that walks one phase ladder. Cross-chain settlement (Xochi mandates, multi-party escrow) wants two on-chain calls in parallel followed by a reduction.
- **Symphony** GraphAdapter is a 5-node strictly-sequential pipeline (`tracker_poll -> candidate_selection -> runner_dispatch -> evidence_collection -> completion` at `packages/raxol_symphony/lib/raxol/symphony/workflow/graph_adapter.ex:18-30`). The orchestrator gets concurrency at the *process* level by spawning multiple workers (`DynamicSupervisor` + `max_concurrent_agents`), each running the graph independently. The graph itself can't fan out.
- **Future Phase 26 sandboxed agents** will want to dispatch sub-tasks in parallel inside one workflow run rather than orchestrating that at the agent's `update/2` callback.

The single existing parallel-adjacent feature is `ConditionalEdge.chooser` (in `lib/raxol/workflow/edge.ex:51-73`): its return type is documented as `(state -> id | [id])` but the runtime only honors single-id returns. `runtime.ex:813-836` `pick_next/2` returns `{:ok, single_id} | :no_match | {:error, _}`; a list of ids is not destructured. That mismatch is the cleanest seam to extend.

### What ADR-0015 said about deferring

ADR-0015 (joins) quoted them explicitly:

> Join nodes (`add_join/4`) act as barriers: multiple incoming edges feed an N-arity reducer that produces the next state.

And on channels:

> Channels (`add_channel/4`) declare typed reducers between nodes. A workflow that fans out to three parallel branches each emitting a partial state can reduce them through a `Channel{:partial, into: :final, with: &Map.merge/2}` declaration.

ADR-0015 listed the deferred work plainly: distributed execution, joins, channels. Phase 25 was "make the single-branch substrate solid", and Phase 25 succeeded: `MIX_ENV=test mix test test/raxol/workflow/` passes 143/0 today.

### Why this is a runtime change, not a library

`Raxol.Workflow.Async` already provides `async_invoke/3` and `stream_events/3` for *external* concurrency: spawn a workflow run on another process, stream its events back. That doesn't help: the *graph itself* is still sequential. A consumer that wants two memo writes to happen at the same time can't express that as a graph; they have to spawn a Task inside one node's body and lose the runtime's checkpoint + retry + compensate + telemetry semantics for the parallel work. Graph-level concurrency means those semantics extend uniformly to the parallel branches.

### Greenfield design constraints

ADR-0015 cited `caudena/beam_weaver` as a port reference but did not adopt its concurrency layer; LangGraph's channel system (LastValue, Topic, Append, ephemeral) influenced the naming but Raxol's existing reducer-state idiom (state map + functional update) is already expressive enough to avoid shipping N reducer types. The design space is open.

## Decision

**Add `add_join/4`, `add_channel/4`, and explicit fan-out semantics to `Raxol.Workflow.Graph`. Add a new `JoinEdge` edge type. Extend the runtime to spawn, track, and barrier-collect parallel branches. Extend checkpoint metadata with `branch_id`.**

The primitives in concrete shape:

### `add_channel/4`

Declares a typed reducer for a key in the state map. Multiple branches that write to that key get their contributions reduced via the declared function on join.

```elixir
Graph.new(:partial_collect)
|> Graph.add_channel(:findings, into: :findings, with: &Map.merge/2)
|> Graph.add_node(:scout_a, fn s -> {:ok, Map.put(s, :findings, %{a: "..."})} end)
|> Graph.add_node(:scout_b, fn s -> {:ok, Map.put(s, :findings, %{b: "..."})} end)
|> Graph.add_node(:scout_c, fn s -> {:ok, Map.put(s, :findings, %{c: "..."})} end)
|> Graph.add_node(:report, fn s -> {:ok, Map.put(s, :report, summarize(s.findings))} end)
|> Graph.add_edge(:__start__, :__fan_out__)
|> Graph.add_conditional_edge(:__fan_out__, [:scout_a, :scout_b, :scout_c],
     fn _ -> [:scout_a, :scout_b, :scout_c] end)  # fan-out: list return is now honored
|> Graph.add_join(:report, [:scout_a, :scout_b, :scout_c])
|> Graph.add_edge(:report, :__end__)
```

`add_channel/4` is metadata only: it doesn't add nodes or edges. It registers `{channel_name, %{into: key, with: reducer}}` on the Graph struct's new `channels` field. The Compiled struct picks it up.

### `add_join/4`

Marks a node as a barrier. The runtime holds at the join until all named upstream branches reach it, then merges their states (per any declared channels for keys those branches wrote) and runs the join's node body once with the merged state.

```elixir
add_join(graph, target_node_id, upstream_ids, opts \\ [])
```

- `target_node_id`: the join's own node id (must have been added via `add_node/3,4`).
- `upstream_ids`: the list of branch nodes that must complete before the join runs. Must match the candidates of an earlier `add_conditional_edge` exactly (compiler validates).
- `opts`:
  - `:reduce`: explicit reducer `(state_list -> merged_state)`. Default: apply per-channel reducers; for keys not covered by a channel, use last-write-wins by branch order.
  - `:timeout_ms`: max wall-clock to wait for all branches. On timeout, the join fails with `{:error, {:branch_timeout, missing_branches}}`. Default: inherit the run's `:run_timeout_ms`.

A `JoinEdge` edge type is created: `%JoinEdge{from: target_node_id, upstream: [ids], reducer: opts}`. The Compiled struct indexes it under `joins_by_node` for O(1) barrier lookup. The runtime keeps a `branch_completions` map per run keyed on `target_node_id` and counts down as branches arrive.

### Fan-out semantics

`add_conditional_edge` already accepts a chooser returning `id | [id]`. The current runtime ignores the list case (only `{:ok, id}` is processed at `runtime.ex:813-836`). The change: `pick_next/2`'s return type becomes `{:ok, id | [id]} | :no_match | {:error, _}`, and `traverse/6` handles the list case by spawning each branch as a child execution.

Concretely, the runtime gets a new `step_fan_out/7` clause: spawn each branch via a tracked `Task.async_stream`, each task runs `step/6` from the branch's entry node. The parent task blocks at the next `JoinEdge` lookup keyed on any branch's downstream. When all branches commit a checkpoint that is the upstream of a join, the parent merges and continues.

### Branch tracking via checkpoint metadata

Pause checkpoints today carry `%{node_id, run_id, graph_id, interrupt_reason, paused_at}`. After this ADR, every checkpoint (success and pause) carries an optional `branch_id`:

```elixir
metadata: %{
  node_id: current_id,
  run_id: run_id,
  graph_id: compiled.id,
  branch_id: branch_id  # nil for sequential paths; {join_id, branch_index} for parallel
}
```

`branch_id` is `nil` for any checkpoint that's not inside a parallel branch (which is *every* checkpoint in any existing graph, full back-compat). Inside a parallel branch, it's `{join_id, branch_index}` where `branch_index` is the position in the upstream list passed to `add_join/4`. The Saver's `list_paused/2` (per ADR-0017) returns all paused branches as separate entries; consumers can group by `run_id` to see "this run has three branches, two are awaiting CI, one is awaiting human approval."

`Saver` callback signature stays unchanged. The shape change is in metadata, which is opaque to the Saver.

### Telemetry

Extend `:node` events with optional `branch_id` in metadata. No new namespace. Existing consumers see no change for sequential graphs. Consumers that want branch-level instrumentation filter on `metadata.branch_id != nil`.

Two run-level events stay unchanged: `[:raxol, :workflow, :run, :started | :completed | :failed]` fire once per run, not per branch. Per-branch lifecycle is observable through `:node` events with `branch_id`.

### Per-branch failure semantics

`failure_policy: :retry` runs per-branch (retries that branch only, parent stays at the join). `failure_policy: :compensate` runs reverse-order through all successfully-executed nodes including parallel ones, treating concurrent branches as if they had completed sequentially in `branch_index` order. `failure_policy: :halt` (the default) fails the whole run on any branch failure.

The catch: compensation in a forked region runs in branch order, not in wall-clock-completion order. This is documented as "saga semantics over a topological reverse"; if a consumer needs strict wall-clock reversal, they should serialize their compensation through a side effect rather than relying on the runtime's order.

### Interaction with pauses (ADR-0017)

A pause inside a parallel branch is a pause on that branch only. Other branches continue. The pause checkpoint's metadata carries `branch_id`, so `list_paused/2` returns one row per paused branch. `Compiled.resume/4` with a `run_id` resumes the *first paused branch found* (deterministic by `branch_id`); a `:branch_id` opt on `resume/4` selects a specific branch. The parent's join wait is unaffected; it counts down only when a branch reaches the join (resumed or not).

The Workflow `:paused`/`:resumed` events fire per-branch, carrying `branch_id` in metadata.

### Compile-time validation

`Graph.compile/2` validates:

- Every `JoinEdge.upstream` references nodes that exist and are downstream of a single `ConditionalEdge` whose `candidates` exactly match the upstream list (no extra, no missing).
- No two `JoinEdge`s share an upstream node (a branch ends at exactly one join).
- No cycles through a join (the parallel region must be a DAG; the rest of the graph can still cycle).
- Every channel name in `add_channel/4` is unique within the graph.
- For every key declared in a channel, every branch in any fan-out region that writes to that key uses the same channel name (compile-time check via static analysis of node bodies is out of scope; runtime fail-loud if two branches write different shapes is the fallback).

Compile failures match the existing error tuple shape from ADR-0015's `compile/2`: `{:error, {:join_upstream_mismatch, join_id, expected, got}}` etc.

## Consequences

### What becomes possible

- **raxol_acp cross-chain settlement** can express two on-chain calls (e.g., `createMemo` on chain A and `createMemo` on chain B) as parallel branches, with a join that reconciles their tx_hashes before advancing the phase. Today this requires either two sequential calls (slower) or a Task.async_stream inside one node (loses retry + compensate + checkpoint per call).
- **Symphony GraphAdapter** can fan out across multiple candidate issues inside one workflow run rather than relying on `DynamicSupervisor` slot management. The orchestrator-level concurrency stays; the graph-level concurrency becomes available for cases where the parallel work is logically one unit.
- **Phase 26 sandboxed agents** can dispatch parallel sub-tasks (one shell command per branch, one file edit per branch) inside one workflow with uniform sandbox + thread-log + policy semantics. The agent doesn't have to choose between "the runtime gives me retry/compensate" and "I can do things in parallel."
- **Channels generalize.** A workflow that wants "the latest of N branches" uses `with: fn _old, new -> new end`. "Sum of partial counts" uses `with: &Kernel.+/2`. "Topic with append-only history" uses `with: fn old, new -> old ++ [new] end`. One declaration shape covers what LangGraph splits into 4+ channel types.
- **Branch-level observability.** `:node` telemetry events carry `branch_id`; dashboards can render per-branch lifecycle without consuming a new namespace.

### What costs we accept

- **Runtime complexity grows.** The sequential `step -> traverse -> step` loop becomes a state machine that tracks open branches per run, blocks on joins, handles per-branch failures + retries + compensations + pauses. The new code is bounded (~400 LOC of runtime + ~150 of compile-time validation + ~200 of test coverage) but it is real concurrency-aware code with race-condition surface.
- **`branch_id` is added to checkpoint metadata everywhere.** Existing checkpoints have `branch_id: nil` (which sequential code already handles via map access). Stored checkpoints from before this ADR don't have the field at all; reading them with the new runtime gets `nil` from `Map.get/3`. Forward compatible; not backward compatible from the new runtime's perspective.
- **The chooser-returns-list path goes from "documented but ignored" to "load-bearing".** Any third-party Graph builder that returned lists from its chooser was previously seeing `{:error, {:chooser_returned_non_id, list}}`, and presumably has been writing single-id choosers. After this ADR, list returns become valid. No behavior change for single-id choosers.
- **Compensation order in parallel regions is topological, not temporal.** If branch A finishes in 100ms and branch B in 50ms, and the join later fails, compensation runs A's nodes before B's (because A is the first branch in the upstream list). For most consumers this is fine; for state-dependent compensation it could matter. Documented in `failure_policy: :compensate`'s moduledoc.
- **Saver shape change is metadata-only.** Adapters don't need to change. Pre-ADR Saver implementations that strip metadata to specific keys would silently drop `branch_id`; the documented contract is "Saver returns metadata verbatim from `put/3`" so any adapter that does that is correct.
- **No cancellation cascade.** If branch A fails with `:halt`, branches B and C don't get killed; they finish their current node and then the run fails when their next checkpoint commits. Acceptable trade-off: cancellation cascade requires linking the parent process to each branch task, which complicates the `Task.async_stream` shape and breaks the per-attempt span isolation that retry semantics rely on. Cascaded cancellation can land as a follow-up.

### What this ADR does not decide

- **Distributed parallel execution.** Branches run on the same BEAM node. ADR-0015 deferred distributed execution to Phase 26+; this ADR holds that line.
- **Dynamic branch counts.** `add_join/4`'s `upstream_ids` is static. A future "fan out over a runtime-decided list" needs a separate primitive (`add_dynamic_fan_out/4`) that includes runtime branch tracking; out of scope here.
- **Multi-channel reducers per join.** Each channel is independent; a join with three channels reduces three keys independently. Cross-channel reducers (e.g., "reduce key A and key B together with a combined function") aren't supported. Workaround: write the cross-key reduction in the join node's body.
- **Cancellation cascade on branch failure.** Branches finish their current node; the run fails on the next checkpoint commit. Cascading kills land as a follow-up if a consumer needs them.
- **Backpressure across branches.** All branches run concurrently up to the BEAM scheduler limit. A `:max_parallelism` opt on the fan-out edge is a follow-up.
- **Streaming channel updates.** A channel that emits its current value on every branch update (rather than only at the join) is a real LangGraph feature; deferring because the current `Async.stream_events/3` already gives consumers per-node update events that they can fold themselves.
- **Sub-graph composition (graph of graphs).** Wrapping a Compiled graph as a node in a parent graph; out of scope, would warrant its own ADR.

## Alternatives considered

### Spawn `Task.async_stream` inside one node body

Consumers can already do this. The runtime gives them retry on the node (which is the whole stream), checkpoint on success, compensate if the whole stream fails. It does not give them per-branch retry, per-branch checkpoint, per-branch compensate, per-branch telemetry, or per-branch pause.

Rejected as the canonical answer because the cost-of-graph-level-parallelism is real (consumers re-implement these semantics ad-hoc) and the value of graph-level-parallelism is uniform semantics across the parallel work. The Task-in-node path stays available for cases where the parallel work is genuinely opaque (e.g., a fire-and-forget log shipping) and doesn't need any of the runtime's guarantees.

### Two new edge types: `ForkEdge` and `JoinEdge`

Add `ForkEdge{from: id, branches: [id]}` instead of extending `ConditionalEdge` to honor list returns. Pair with `JoinEdge`.

Rejected. `ConditionalEdge`'s chooser already returns `id | [id]` per its docstring; the runtime is the only thing not honoring the list case. Adding a parallel `ForkEdge` doubles the surface for the same semantic ("decide which branches to run next") and forces consumers to choose between dynamic-routing (`ConditionalEdge`) and parallel-fan-out (`ForkEdge`) when often they want both. Honoring the existing contract is cheaper and more orthogonal.

### Channels as first-class graph nodes

Make channels be nodes (`add_channel_node/3`) that branches send messages to, with the channel node's body being the reducer. Inspired by LangGraph's channel-as-node abstraction.

Rejected. It adds a node-execution event for every reduce step, which inflates telemetry by `branches * keys`. The current proposal (channels are metadata on the Graph struct, reducers fire once at the join) is cheaper, and the consumer can still observe per-branch updates via the existing node-completion events.

### Cancellation cascade by default

When a branch fails, kill the others immediately.

Rejected as default. The semantics are surprising (a parallel region's outcome depends on which branch failed first), and the implementation complicates `Task.async_stream` shape. Documented as a follow-up to ship when a consumer demonstrates need.

### Distributed branches on multi-node BEAM clusters

Branches dispatch through `:rpc.async_call/4` or libcluster to other nodes. Scales the runtime horizontally.

Rejected. ADR-0015 deferred distributed execution explicitly; nothing about this ADR's design precludes adding it later. The single-node branch model already covers every consumer's current need; cross-node is a Phase 26+ question.

### Preserve sequential-only with better external concurrency primitives

Add helper functions for "fan out across N runs of the same workflow, reduce their results externally." Effectively `Async.async_invoke/3` + a reducer.

Rejected as sufficient. The whole point of graph-level concurrency is that the parallel work *is one workflow* with shared retry/compensate/checkpoint semantics. Spawning N independent runs gives N independent retry policies, N independent compensation chains, N independent thread_ids in the Saver. The unified abstraction is the value.

## Validation

How we know the design is right:

- **The sequential test suite passes unchanged.** Every existing workflow test in `test/raxol/workflow/` (143 today) runs against the new runtime without modification. The parallel code paths are dormant until a graph uses `add_join/4`.
- **A reference parallel workflow lands as `test/raxol/workflow/parallel_test.exs`.** Two-branch fan-out, three-branch fan-out, mixed channel reducers, branch-failure-during-fan-out, pause-inside-branch, retry-per-branch, compensate-across-branches. ~12 tests covering the new surface.
- **`raxol_acp` adopts joins for a cross-chain settlement demo.** ACP today doesn't need joins (each ACP job walks one chain). A demo workflow under `packages/raxol_acp/examples/` that simulates a two-chain settlement validates the API ergonomics from a real consumer's perspective.
- **Symphony GraphAdapter stays sequential.** No changes required. The ADR-0019 work doesn't touch Symphony's graph; that adoption is a separate follow-up gated on Symphony's PausedSaver work landing.
- **Telemetry round-trip:** a fan-out -> join run emits `[:raxol, :workflow, :node, :*]` events with `branch_id` set on the parallel branches and `nil` on the rest. Property test verifies branch_id is set if and only if the node is downstream of a `ConditionalEdge` whose chooser returned a list.
- **Compile errors match the ADR-0015 shape:** structured tuples, no exceptions thrown, every invalid join configuration produces an actionable error.

## References

- ADR-0015: Workflow Graph (`Raxol.Workflow.*`): Phase 25 runtime, this ADR's predecessor
- ADR-0017: Workflow paused-run query and pause-checkpoint contract: the metadata-extension precedent
- ADR-0018: Operator-flow contract for paused runs: the per-channel surfacing the new branch-level events will flow through
- `lib/raxol/workflow/runtime.ex:29-30` (the deferral comment quoted in Context)
- `lib/raxol/workflow/runtime.ex:813-836` (`pick_next/2`, the seam)
- `lib/raxol/workflow/edge.ex:51-73` (`ConditionalEdge`, which already accepts list-returning choosers)
- `lib/raxol/workflow/graph.ex:111` (`add_conditional_edge/4`, the public builder)
- `lib/raxol/workflow/checkpoint.ex:31-48` (Checkpoint struct, where `branch_id` lands in metadata)
- `packages/raxol_symphony/lib/raxol/symphony/workflow/graph_adapter.ex:18-30` (Symphony's sequential pipeline, the largest existing consumer)
- LangGraph's channel design (referenced for naming, not constraint)
- `caudena/beam_weaver` (cited in ADR-0015; concurrency layer not adopted in Phase 25)
