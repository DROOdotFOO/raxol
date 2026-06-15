# ADR-0015: Workflow Graph (`Raxol.Workflow.*`)

## Status

Accepted, 2026-06-15. Lands as Phase 25 of the jido + beam_weaver extraction plan opened on 2026-06-14. ADRs 0005 (plugin system), 0012 (MCP as rendering target), 0013 (event dispatch backpressure), and 0014 (Telegram Guardian behaviour) are the closest priors. Phase 24's effect-system landing (PRs #276, #277, #280, #281) is the direct dependency: the CloudEvents envelope, `causation_id`, and `with_dispatch_span` machinery are all load-bearing for what this ADR proposes.

## Context

raxol has two consumers today that need a multi-step, observably-orchestrated, optionally-resumable execution primitive, and neither has one.

`raxol_symphony` parses a `WORKFLOW.md` into a flat `%{config, prompt_template}` map (`Raxol.Symphony.Workflow`). The `Orchestrator` polls a tracker, claims a candidate issue, dispatches it to a Runner (RaxolAgent or Codex), and watches the run to completion. The "workflow" is a single prompt expanded by `PromptBuilder`. Multi-step flows, branching, joins, durable checkpoints, and human-in-the-loop interrupts all sit outside that primitive. Symphony has been honest about this: the README calls the current path "prompt-only" and treats anything richer as future work.

`raxol_acp` Jobs already model a phased lifecycle (`request -> negotiation -> transaction -> evaluation -> completed`) with `Job.Server` and `Job.StateMachine`, but the per-job process is the only durability story. A `Job.Server` crash mid-`createMemo` re-enters from `Store.load/1`, which restores memo history but not the in-flight on-chain operation. ACP jobs that span hours (waiting on buyer signature) or days (cross-chain settlement) effectively rebuild their own resumption story per phase. There's no shared substrate to lean on.

The forces shaping this ADR:

- **OTP fit.** A workflow primitive on the BEAM has to feel like a BEAM primitive: supervised, message-friendly, hot-reloadable, with structured shutdown. A direct port of LangGraph (a Python DAG executor) would import a global-state model that fights `Raxol.Core.Behaviours.BaseManager` and the existing dispatcher idioms.
- **LangGraph familiarity is real.** LangGraph's StateGraph (compile -> invoke -> stream_events -> resume) is the API users will arrive expecting. Naming things the same and shaping the API in parallel reduces friction for the population of users coming from Python agent stacks. caudena/beam_weaver already proved an OTP-flavoured port is small and tractable; that reference exists, and pulling it apart is cheaper than greenfield design.
- **Resumability is the load-bearing feature.** Without durable checkpoints, multi-step workflows on long-running ACP jobs are no more recoverable than the current per-phase state machine. With them, `Compiled.resume/3` plus a Saver backend (DETS at minimum) gives ACP a substrate that survives process restarts and node restarts without case-by-case wiring.
- **Phase 24 already paid for observability.** The CloudEvents envelope, `causation_id`, `TraceContext.with_span`, and `TelemetryAdapter` are all in place. A Workflow runtime that emits per-node start/stop/interrupt/resume events through the same telemetry path gets full causation chains for free. Without Phase 24 this would be a much bigger undertaking; with it, the cost is mostly wiring.
- **No mandatory adoption.** Symphony's current consumers run with the prompt-only path. ACP's current Job model works for the canonical flows. The Workflow primitive must be *opt in*, layered on top, and indifferent to whether the rest of the system uses it.

The shape we pick has to fit alongside the existing TEA runtime, the existing agent framework, and Symphony's prompt-only path without leaking into any of them.

### Why the workflow primitive does not live in a new package

`raxol_acp` and `raxol_symphony` are the two motivating consumers. `raxol_agent` will benefit too (Pipelines + Actions become composable inside a graph). All three already depend on main raxol. A new `raxol_workflow` package would require either (a) duplicating the dispatcher's directive plumbing or (b) re-exporting `Raxol.Core.Runtime.Directive` from a third package; both options widen the dep graph for no real isolation gain. The Workflow primitive uses `Directive.Executor` directly, leverages `TraceContext.with_span`, and emits via `TelemetryAdapter`. That coupling is intrinsic, not incidental.

The dep graph from CLAUDE.md is already non-trivial (`raxol -> {core, terminal, sensor, mcp, liveview, plugin}`, `agent -> raxol`, `payments -> agent runtime: false`, `acp -> payments + agent runtime: false`). Adding a sixth top-level package for a primitive that piggybacks on the runtime would be cargo-culted modularity.

### Why the workflow primitive does not live inside `raxol_symphony`

Symphony is one consumer. ACP's resumable jobs are the bigger and more architecturally interesting use case (real money, real chain state, longer wall-clock). Placing the primitive inside `raxol_symphony` would force `raxol_acp` to take a Symphony dependency to use Workflow, which violates the established direction of arrows (`acp -> payments`, no Symphony coupling) and pulls Tracker, Orchestrator, and Codex Runner into ACP's compile tree for no reason.

Furthermore, the Workflow primitive is genuinely orthogonal to Symphony's *job dispatch* model. Symphony picks one workflow per issue and runs it to completion; Workflow is the *engine* underneath. The right shape is: Workflow lives where the runtime lives; Symphony plugs into it via an optional adapter.

### Why not extend `raxol_agent`'s `Action` + `Pipeline`

`Raxol.Agent.Action` and `Raxol.Agent.Action.Pipeline` are already a composable execution surface. A Pipeline is a linear sequence of Actions, threading a context through each step. The natural question is: why not just extend Pipeline with branching, joins, and checkpoints?

The answer is shape and lifetime. Pipelines are designed for *intra-agent* composition: an Action returns `{:ok, context, effects}`, the Pipeline threads context, all in one process for the duration of one agent call. Workflows are designed for *cross-process, cross-restart, cross-timezone* execution: a node might be a function, an Action, a sub-graph, a human approval gate, or an external HTTP call that times out and resumes 12 hours later. Pipelines have no checkpoint contract, no interrupt mechanism, no concept of "this run is paused; restart the BEAM and we'll pick up where we left off." Bolting that on would mutate Pipeline's contract for every existing caller.

The cleaner shape is: Workflow nodes can *contain* Actions or Pipelines (a `node` wrapping `{:action, MyAction, args}` is fine), but Workflow is its own primitive with its own lifecycle.

### What Phase 24 unlocked

Phase 24's foundation makes a meaningful difference to what this primitive can promise:

- `Raxol.Core.Events.CloudEvent` v1.0 envelope means every node's telemetry event is a structured, externally-readable record (subject = node name, type = `raxol.workflow.<event>`, source from app env).
- `TraceContext.causation_id` plus `with_dispatch_span` (the multi-hop fix from PR #281) means a Workflow node emitting a `Directive.send_agent` propagates causation through the chain, and the next workflow run that consumes that agent's reply will see `causation_id == that node's span_id`. Full lineage from workflow start to terminal effect.
- `Raxol.Core.Runtime.Directive.Executor` protocol means Workflow nodes can emit effects (shell, async, send_agent, ACP directives, Payments.Pay) using the same protocol any TEA app uses. No second effect system.

Without Phase 24, this ADR would have to define its own envelope, causation strategy, and effect protocol. With Phase 24, the Workflow runtime is mostly an orchestrator over machinery that already exists.

## Decision

We will add `Raxol.Workflow.*` to main raxol as the canonical multi-step orchestration primitive. The surface is modeled on LangGraph's StateGraph (familiar) with OTP-native execution semantics (genuine). Adoption is opt-in: Symphony keeps its prompt-only path as the default and gains an opt-in `:graph` mode; ACP gains a resumable Job substrate that the existing `Job.Server` lifecycle can adopt incrementally.

### Namespace and package placement

Top-level `Raxol.Workflow.*` inside main raxol. Submodules:

- `Raxol.Workflow.Graph` -- immutable graph builder (the construction-time API)
- `Raxol.Workflow.Compiled` -- the runtime API after `Graph.compile/2`
- `Raxol.Workflow.Node` -- node descriptor structs (`FunctionNode`, `BehaviourNode`, `TypedNode`)
- `Raxol.Workflow.Edge` -- edge descriptor structs (`Edge`, `GuardedEdge`, `ConditionalEdge`)
- `Raxol.Workflow.Checkpoint` -- checkpoint records and `Checkpoint.Saver` behaviour
- `Raxol.Workflow.Checkpoint.Saver.Ets`, `Raxol.Workflow.Checkpoint.Saver.Dets` -- adapters
- `Raxol.Workflow.Execution.Scratchpad` -- per-task execution state (process dict, justified)
- `Raxol.Workflow.Execution.Channel` -- typed channel reducers between nodes
- `Raxol.Workflow.Interrupt` -- the throw-caught exception used to pause a run

No new package. No optional Mix dep. Workflow is part of `raxol` and ships with it.

### Graph builder shape

`Raxol.Workflow.Graph` is an immutable struct built via pipe-friendly functions and frozen with `compile/2`:

```elixir
Raxol.Workflow.Graph.new(:my_flow)
|> Graph.add_node(:fetch, &fetch_data/1)
|> Graph.add_node(:summarize, {MyAction, %{model: "claude-haiku-4-5"}})
|> Graph.add_node(:notify, &send_slack/1)
|> Graph.add_edge(:fetch, :summarize)
|> Graph.add_edge(:summarize, :notify)
|> Graph.add_edge(:notify, :__end__)
|> Graph.compile(saver: Workflow.Checkpoint.Saver.Ets)
```

Nodes are one of three shapes:

- **FunctionNode**: a 1-arity function `(state -> {:ok, state} | {:interrupt, value} | {:error, reason} | {:effects, [directive], state})`
- **BehaviourNode**: a module implementing `Raxol.Workflow.Node` (callbacks: `init/1`, `run/2`, optional `compensate/2`)
- **TypedNode**: a struct with a `Raxol.Workflow.Node.Executor` protocol impl (mirrors the Directive pattern; lets `raxol_acp` register typed nodes like `%Workflow.Node.ACPCreateMemo{...}` with custom telemetry)

Edges are static (`add_edge/3`), guarded by a predicate (`add_guarded_edge/4`), or conditional fan-out (`add_conditional_edge/3` returning a list of next nodes). Join nodes (`add_join/4`) act as barriers: multiple incoming edges feed an N-arity reducer that produces the next state.

Channels (`add_channel/4`) declare typed reducers between nodes. A workflow that fans out to three parallel branches each emitting a partial state can reduce them through a `Channel{:partial, into: :final, with: &Map.merge/2}` declaration.

`compile/2` validates the graph (no orphaned nodes, no cycles unless explicitly marked recursive, every node has a path to `:__end__`), freezes the structure, and returns a `Compiled` struct opaque to callers.

### Compiled runtime API

`Raxol.Workflow.Compiled` exposes four entry points:

- `invoke(compiled, initial_state, opts)` -- run synchronously to completion or interrupt. Returns `{:ok, final_state}` | `{:interrupted, run_id, state}` | `{:error, reason}`.
- `async_invoke(compiled, initial_state, opts)` -- spawn the run under `DynamicSupervisor`, return the run pid + ref. Caller subscribes to `Phoenix.PubSub` events to follow progress.
- `stream_events(compiled, initial_state, opts)` -- returns a lazy `Stream` of `Raxol.Core.Events.CloudEvent` structs as the run progresses. Each node emits start/stop events; the stream completes when the run terminates.
- `resume(compiled, run_id, resume_value, opts)` -- consume an interrupt: hydrate from the checkpoint, feed `resume_value` to the scratchpad's resume queue, continue execution. Returns the same shape as `invoke/3`.

Failure policy (`:retry`, `:halt`, `:compensate`), per-step timeout (`step_timeout_ms`), and total run timeout (`run_timeout_ms`) are options on `compile/2`. The runtime emits CloudEvents at the boundaries: `raxol.workflow.run.started`, `raxol.workflow.node.started`, `raxol.workflow.node.completed`, `raxol.workflow.node.failed`, `raxol.workflow.run.interrupted`, `raxol.workflow.run.completed`. Each event carries `trace_id`, `span_id`, `parent_span_id`, and `causation_id` via the Phase 24 propagation; subscribers can reconstruct the full execution graph from telemetry alone.

### Checkpoint Saver protocol

`Raxol.Workflow.Checkpoint.Saver` is a behaviour modeled on beam_weaver's port of LangGraph's CheckpointSaver:

```elixir
@callback get_tuple(config :: map(), thread_id :: binary()) ::
            {:ok, Checkpoint.t()} | {:error, term()}
@callback list(config :: map(), thread_id :: binary(), limit :: pos_integer()) ::
            {:ok, [Checkpoint.t()]}
@callback put(config, thread_id, checkpoint, metadata, new_versions) ::
            :ok | {:error, term()}
@callback put_writes(config, thread_id, task_id, writes, channel_versions) ::
            :ok | {:error, term()}
@callback delete_thread(config, thread_id) :: :ok | {:error, term()}
@callback next_version(config, thread_id, channel) :: pos_integer()
```

Two adapters ship in this phase:

- **Ets** -- in-process ETS table, cleared at app stop. Default for tests and short-lived runs.
- **Dets** -- file-backed DETS, survives BEAM restarts. Default for `raxol_acp` durable jobs.

A `Saver.Postgrex` adapter is a natural follow-up for shared deployments but is *not* in scope for Phase 25. The behaviour shape is meant to support it without modification.

A `Checkpoint` is a struct with `thread_id`, `step`, `state`, `metadata`, `parent_step`, `created_at`. Saves are append-only: `put/5` adds a new checkpoint without mutating prior ones. `list/3` returns them newest-first. This makes time-travel debugging (replay the run from any prior checkpoint) a one-call operation.

### Interrupt and resume

`Raxol.Workflow.Execution.Scratchpad` stores per-task execution state in the process dictionary. This is one of the rare justified cases for `Process.put/get`: the scratchpad is process-local, lives only for the duration of one node's execution, must be transparently inherited by spawned tasks within that node, and cannot leak across runs because each run spawns its own process tree.

A node interrupts by calling `Raxol.Workflow.interrupt(value)`, which:

1. Records `value` in the scratchpad's interrupt slot
2. Forces a checkpoint save (current state + scratchpad)
3. Throws `{:__workflow_interrupt__, value, scratchpad_id}`

The runtime catches this throw, records the checkpoint, returns `{:interrupted, run_id, state}` to the caller. The caller (human, MCP tool, scheduled job) eventually calls `Compiled.resume(compiled, run_id, resume_value)`. On resume:

1. Saver hydrates the latest checkpoint for the thread
2. Scratchpad's resume queue is fed `resume_value`
3. Execution continues from the interrupted node, which re-runs and pulls the resume value from the queue instead of interrupting again

This shape gives human-in-the-loop approval gates a clean idiom: a node that needs approval calls `interrupt(:approval_required)`, the run pauses, an MCP tool or LiveView surface presents the pending approval, the user clicks Approve, the resume value `:approved` flows back into the node, and the node continues. No special-case state, no out-of-band signaling.

### Symphony adoption (opt-in)

`raxol_symphony` adopts via an optional `Raxol.Symphony.Workflow.GraphAdapter`. The adapter is a separate PR (Phase 25 follow-up) that translates a parsed `WORKFLOW.md` config into a `Raxol.Workflow.Graph` (nodes for tracker poll, candidate selection, runner dispatch, evidence collection, completion), then dispatches via `Compiled.async_invoke/3`. Opt in by setting `workflow_mode: :graph` in symphony config. The current `Orchestrator` BaseManager + prompt-only path stays the default.

This boundary is firm: nothing in the Phase 25 core touches `raxol_symphony`. The adapter is purely additive on the Symphony side, and the Workflow core has no awareness of Symphony's existence.

### `raxol_acp` adoption (later phase)

`raxol_acp` Jobs are not migrated in Phase 25. The Workflow primitive becomes *available* to ACP; a follow-up phase (likely 27 or 28) replaces or augments the existing `Job.Server` state machine with a Workflow-backed implementation. The reason for the gap: ACP just landed canonical alignment, and a Job migration is a real piece of work that deserves its own ADR.

## Consequences

### What becomes possible

- **Resumable multi-step workflows** across BEAM restarts (Saver.Dets) and across deployments (Saver.Postgrex when added). The substrate that ACP needs for hours-long buyer-signature waits.
- **Human-in-the-loop interrupts** with a clean primitive (no special-case state, no polling). MCP tools, LiveView UIs, and Symphony's terminal dashboard all gain the ability to gate workflow steps on user input.
- **Time-travel debugging** by replaying from any prior checkpoint. Append-only Saver semantics make this a property of the data model, not a separate feature.
- **Full causation chains** through CloudEvents emission. A workflow run's telemetry is enough to reconstruct execution order, branching, joins, and effects.
- **Composability with existing raxol primitives.** A Workflow node can wrap an `Agent.Action`, dispatch a `Directive.SendAgent`, emit a `Payments.Directive.Pay`, or call `ACP.Directive.CreateMemo`. The Workflow runtime is an orchestrator over the existing effect system, not a replacement.

### What costs we accept

- **Engineering scope.** Phase 25 is ~4-6 weeks of work per the planning estimate. Graph builder + Compiled + Saver + Scratchpad + interrupts + telemetry + tests is multiple PRs.
- **Surface area added to main raxol.** ~12 new public modules under `Raxol.Workflow.*`. Justified by being the canonical primitive, not by being small.
- **Documentation burden.** A LangGraph-shaped API is familiar but non-obvious. The first three users (us, ACP migration, Symphony adoption) will need a real guide, not just `@doc` strings.
- **Property test ergonomics for graph compilation.** Validating "no orphan nodes, no implicit cycles, every node reaches `:__end__`" property-style requires graph generators. Not hard, but real work; planned.
- **Process-dict scratchpad is a controlled exception.** The pattern is documented and contained, but every additional use of `Process.put/get` in raxol's codebase requires the same diligence. We accept this for the scratchpad and nowhere else.

### What this ADR does not decide

- The exact shape of the `raxol_acp` Job migration. That's a separate phase with its own ADR.
- Postgrex Saver shape or schema. The behaviour leaves room; a future PR adds the adapter.
- Whether `Raxol.Agent.Action.Pipeline` becomes a thin wrapper over `Raxol.Workflow.Graph`. Probably not, but worth revisiting once the Workflow runtime is real.
- Whether Symphony's `WORKFLOW.md` format evolves to expose graph constructs directly. The first GraphAdapter translates the existing flat config; a richer `WORKFLOW.md` schema is a downstream decision.
- Distributed execution. The runtime is single-node in Phase 25. `Raxol.Swarm` already exists for cross-node coordination; a future phase can wire a node off-host without changing the Workflow API.

## Alternatives considered

### Vendor LangGraph directly via a Python NIF / Port

Rejected. LangGraph's runtime model (global state, Python coroutines, sync/async duality) does not map cleanly onto BEAM idioms. The interop cost (serializing state across the Port boundary, owning a Python process) erases the supposed savings of not writing the runtime ourselves, and the resulting system would be the hardest to debug of any option.

### Pull beam_weaver in as a dependency

Rejected. caudena/beam_weaver was 2 days old when researched and ships a massive surface area (RAG stack, vector stores, embedding profiles, provider validation, Runnable protocol) that has no place in raxol. The graph + checkpoint + scratchpad code is small enough to port directly with attribution; pulling the package would force us to either depend on the entire surface or fork it. Forking inherits the maintenance burden without the upstream's signal.

### Layer it on top of `Raxol.Agent.Action.Pipeline`

Rejected per the "Why not extend Action + Pipeline" section above. Pipelines and Workflows have different lifetimes, contracts, and surface areas; sharing a primitive would compromise both.

### Put it in a `raxol_workflow` package

Rejected per the "Why the workflow primitive does not live in a new package" section above. The intrinsic coupling to the dispatcher's directive plumbing and CloudEvents emission makes a separate package a packaging exercise without architectural benefit.

### Use `gen_statem` per workflow

Considered, rejected. `gen_statem` is a great primitive for protocol-style state machines (a few states, well-defined transitions, no branching on arbitrary state values). Workflows have many nodes, branching predicates on rich state, and conditional fan-out; encoding each node as a `gen_statem` state would either explode the state count or require the per-state callback to internally re-dispatch on the workflow's logical state, at which point we've reinvented the runtime worse.

### Use `Saga`-style compensating transactions only (no graph)

Considered, rejected. Sagas are a great pattern for distributed transactions where each step has a defined compensating action. Workflows have nodes that don't compensate (notification, summarization, data fetch). The compensation pattern is a useful failure policy for some workflows (`failure_policy: :compensate`), not a substitute for the graph structure.
