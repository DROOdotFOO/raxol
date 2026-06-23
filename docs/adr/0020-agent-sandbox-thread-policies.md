# ADR-0020: Phase 26: Agent Sandbox, Thread log, declarative Policies

## Status

Proposed, 2026-06-16. Symmetric to ADR-0019 (Workflow concurrency) for the agent stack: ADR-0019 scopes the runtime-side parallel-branch primitive, this ADR scopes the agent-side isolation + audit + policy primitive. Together they frame the next 3-6 months of substrate work. Builds on ADR-0012 (MCP as rendering target), ADR-0017 (paused-run query), ADR-0018 (operator-flow contract), and Phase 24F (Command struct deletion, leaving Directive as the canonical effect shape).

## Context

The agent stack today is feature-complete for the prompt-then-react loop. `use Raxol.Agent` gives an author the TEA callbacks (`init/1`, `update/2`, `view/1`, plus agent-specific `handle_message/2`, `handle_tick/1`, `compaction_config/0`, `command_hooks/0`, `memory_provider/0`, `available_actions/0`). Directives (`Raxol.Agent.Directive.Async`, `Shell`, `SendAgent`) emit effects; the framework dispatches them via the `Raxol.Core.Runtime.Directive.Executor` protocol after Phase 24F. The `CommandHook` behaviour (`packages/raxol_agent/lib/raxol/agent/command_hook.ex:57-75`) gives authors `c:pre_execute/2` + `c:post_execute/3` interception. `PermissionHook` (`packages/raxol_agent/lib/raxol/agent/permission_hook.ex:8-14, 66-82`) ships a five-level mode hierarchy (`:read_only`, `:send_only`, `:workspace_write`, `:full_access`, `:allow`) implemented as a CommandHook.

Three structural gaps emerge as the agent stack picks up real consumers:

### Gap 1: Isolation is one-dimensional

`PermissionHook`'s five modes are linear: each mode is a strict superset of the one below. A consumer that wants "filesystem reads anywhere but network calls only to api.openai.com and api.anthropic.com" cannot express that. The closest fit is `:full_access` (which permits network calls everywhere) plus a per-call check inside the agent's `update/2` body, which puts policy in imperative code rather than declarative configuration. Authors of multi-agent systems (a coordinator + several worker agents) cannot give each worker a different sandbox shape without writing custom CommandHooks per worker.

The structural issue is that `PermissionHook` is a single behaviour with a single mode field. Sandbox is conceptually orthogonal (filesystem, network, shell, inter-agent messaging are independent dimensions) and the current model collapses them into one ladder. Mode `:workspace_write` permits workspace-relative file writes *and* inter-agent messaging *and* async tasks; an author who wants the first but not the second cannot get there.

### Gap 2: No durable, cross-session audit trail

The `ContextCompactor` (`packages/raxol_agent/lib/raxol/agent/context_compactor.ex`) handles in-memory session history compaction. `Agent.Process.maybe_compact_history/2` (lines 340, 372, 411-430) summarizes older messages into a continuation system message when the session goes over `compaction_config.max_tokens`. The agent's working memory holds the *summary*; the original messages are gone from process state.

There is no separate, durable, append-only record of what the agent actually did. After compaction, the question "what tool calls did this agent make in the last 24 hours?" can only be answered by walking telemetry events. After process termination, even that is gone (telemetry handlers are per-session). After server restart, the message history is reconstructed from the ContextStore's ETS snapshot, which is itself ephemeral (`packages/raxol_agent/lib/raxol/agent/context_store.ex`).

The same gap shows up in agent-to-MCP introspection: ADR-0012 made MCP a rendering target derived from the component tree, but agent activity (tool calls, directive emissions, state transitions) is not exposed as an MCP resource. An operator using Claude as an MCP client cannot ask "show me MyAgent's last 100 tool calls"; that data structurally doesn't exist as a durable record.

### Gap 3: Retry / timeout / rate-limit / cache are ad-hoc per call site

Grep for `:retry`, `:timeout`, `:rate_limit`, `:cache`, `backoff` in `packages/raxol_agent/lib/`:

- `Directive.Shell` accepts a `:timeout` option (`directive.ex:73-86`) passed to the executor's Port (`executor.ex:21-26`).
- No `:retry`, `:rate_limit`, or `:cache` infrastructure exists anywhere in `raxol_agent` or `raxol_core`.

Every Action that needs retry, every tool that needs caching, every external API call that needs rate-limiting implements its own. The patterns are well-understood (exponential backoff with jitter, ETS-backed TTL caches, token-bucket rate limiters) but writing them inline pollutes business logic. The cost of *not* having a shared declarative layer is that consumers either skip these primitives (and bugs land in production) or write them ad-hoc (and the patterns diverge across the codebase).

### What ADR-0019 said about Phase 26

ADR-0019 cited Phase 26 sandboxed agents explicitly as the consumer that wants parallel sub-tasks inside one workflow:

> Phase 26 sandboxed agents can dispatch parallel sub-tasks (one shell command per branch, one file edit per branch) inside one workflow with uniform sandbox + thread-log + policy semantics.

That framing names the three primitives this ADR scopes. ADR-0019 deferred the agent-side work; this ADR picks it up.

## Decision

**Add three coordinated primitives to `raxol_agent`: a multi-dimensional `Sandbox` behaviour, a durable `ThreadLog` behaviour, and declarative `Policy.{Retry, Timeout, RateLimit, Cache}` structs. Introduce a `Cache` behaviour as a Phase 26 prerequisite. All three primitives compose at action invocation through a single applier pipeline.**

### 1. `Raxol.Agent.Sandbox` behaviour

A Sandbox is a *declarative* statement of what an agent may do. The framework converts declared Sandboxes to runtime `CommandHook` implementations transparently, but the author writes against the Sandbox surface, not the CommandHook surface.

```elixir
defmodule MyAgent do
  use Raxol.Agent

  def sandbox do
    [
      Sandbox.Filesystem.workspace_only(),
      Sandbox.Network.allowlist([
        "api.openai.com",
        "api.anthropic.com"
      ]),
      Sandbox.Shell.deny_all(),
      Sandbox.SendAgent.allow_only([:worker_a, :worker_b])
    ]
  end
end
```

Five Sandbox dimensions, each a separate module with its own constructors:

| Dimension | Constructors |
| --- | --- |
| `Sandbox.Filesystem` | `workspace_only/0`, `allowlist/1`, `denylist/1`, `read_only/0`, `none/0` |
| `Sandbox.Network` | `allowlist/1`, `denylist/1`, `none/0` |
| `Sandbox.Shell` | `allowlist/1`, `denylist/1`, `none/0`, `deny_all/0` |
| `Sandbox.SendAgent` | `allow_only/1`, `deny/1`, `none/0` |
| `Sandbox.Resource` | `cpu_quota/1`, `memory_quota/1`, `process_quota/1` |

Each constructor returns a struct implementing the `Raxol.Agent.Sandbox` protocol:

```elixir
defprotocol Raxol.Agent.Sandbox do
  @spec authorize(t(), action :: atom(), payload :: term(), ctx :: map()) ::
          :ok | {:deny, reason :: term()}
  def authorize(sandbox, action, payload, ctx)

  @spec to_hook(t()) :: Raxol.Agent.CommandHook.t()
  def to_hook(sandbox)
end
```

The `authorize/4` callback is the canonical check: filesystem sandbox inspects payload for paths, network sandbox inspects for hosts, shell sandbox inspects for binary + arguments. The `to_hook/1` callback is the runtime adapter: every Sandbox becomes a CommandHook so the existing hook chain in `Agent.Process` doesn't change shape. PermissionHook stays as the legacy single-mode entry; new code uses Sandbox.

**Composition**: Sandboxes from `sandbox/0` are appended to `command_hooks/0` at process start. First `:deny` short-circuits, matching the existing CommandHook semantics. An author can use both surfaces during migration: `command_hooks/0` for imperative hooks, `sandbox/0` for declarative isolation, both flow into the same chain.

### 2. `Raxol.Agent.ThreadLog` behaviour

A ThreadLog is an append-only, durable, cross-session record of agent activity. Mirrors the `Raxol.Workflow.Checkpoint.Saver` shape (a behaviour with multiple adapters) but the unit of storage is a `ThreadEvent`, not a checkpoint.

```elixir
@type thread_id :: binary()
@type sequence :: non_neg_integer()
@type kind :: :directive | :tool_call | :tool_result | :message
           | :state_snapshot | :summary | :sandbox_deny | :policy_result

@type event :: %ThreadEvent{
  thread_id: thread_id(),
  sequence: sequence(),
  kind: kind(),
  payload: term(),
  metadata: map(),
  recorded_at: DateTime.t()
}

@callback append(config(), event()) :: {:ok, sequence()} | {:error, term()}
@callback list(config(), thread_id(), opts()) :: {:ok, [event()]}
@callback list_by_kind(config(), thread_id(), kind(), opts()) :: {:ok, [event()]}
@callback latest(config(), thread_id()) :: {:ok, event()} | {:error, :not_found}
@callback truncate(config(), thread_id(), before :: sequence()) :: :ok | {:error, term()}
```

Three adapters ship: `ThreadLog.Ets` (default, in-process, ephemeral with optional periodic snapshot to disk), `ThreadLog.Dets` (file-backed single-node), `ThreadLog.Postgrex` (cross-node durable, schema mirrors `Saver.Postgrex`'s pattern). Adapter choice is per-agent via `thread_log/0` callback:

```elixir
def thread_log do
  {Raxol.Agent.ThreadLog.Postgrex, %{conn: MyApp.Postgrex, table: "agent_threads"}}
end
```

**Interaction with `ContextCompactor`**: when compaction fires and summarizes N messages into one summary, the runtime appends one `kind: :message` event per original message (preserved verbatim) and one `kind: :summary` event recording the compactor's continuation message. The agent's working memory has the summary; the ThreadLog has both the originals and the summary marker. An operator querying "what did the agent see before compaction?" can list `:message` events up to the `:summary` sequence number; querying "what's the agent's current view?" reads the agent state directly.

**Interaction with the Workflow Saver**: the two are independent. `ThreadLog` records agent activity; `Saver` records workflow run state. An agent invoked from a workflow run has both: workflow checkpoints in the Saver (thread_id = run_id), thread events in the ThreadLog (thread_id = agent_id). They don't merge; they live at different abstraction levels.

**MCP integration**: the ThreadLog becomes the durable backing for an `agent://<agent_id>/thread` MCP resource. An operator using Claude as an MCP client can ask "show me MyAgent's last 100 tool calls" and the resource is materialized from `ThreadLog.list_by_kind(config, agent_id, :tool_call, limit: 100)`. The agent activity that ADR-0012 didn't extend to becomes available.

### 3. `Raxol.Agent.Policy.{Retry, Timeout, RateLimit, Cache}` structs

Declarative wrappers applied to Action invocations. Each is a struct; the framework's `PolicyApplier` composes them in declaration order at runtime.

```elixir
defmodule MyAgent.FetchData do
  use Raxol.Agent.Action,
    name: "fetch_data",
    description: "Fetch user data from the upstream API",
    schema: [
      input: [user_id: :string],
      output: [data: :map]
    ],
    policies: [
      Policy.Cache.ets(ttl: :timer.minutes(5), key_fn: &cache_key/1),
      Policy.RateLimit.token_bucket(rate: 10, burst: 20, key_fn: &rate_key/1),
      Policy.Timeout.soft(30_000),
      Policy.Retry.exponential(max_attempts: 3, base_ms: 200, on: [:network_error])
    ]

  def run(params, ctx), do: HTTP.get!(url(params))
end
```

The policies apply outermost-first at invocation: cache check -> rate-limit check -> timeout wrap -> retry wrap -> `Action.run/2`. The reverse order of declaration is intentional: the author lists "what I want true at the top" and the runtime peels them off in order.

**Four policy structs**:

| Struct | Shape | Where state lives |
| --- | --- | --- |
| `Policy.Retry` | `%{max_attempts, base_ms, max_ms, on: [reasons]}` | None (per-invocation) |
| `Policy.Timeout` | `%{wall_ms, soft_deadline_ms}` | None (per-invocation) |
| `Policy.RateLimit` | `%{rate, burst, key_fn, storage}` | `Raxol.Agent.RateLimiter` GenServer per agent |
| `Policy.Cache` | `%{ttl, key_fn, storage}` | New `Raxol.Agent.Cache` behaviour |

**Logging**: every policy decision (retry attempt, cache hit, cache miss, rate-limit reject, timeout fired) is appended to the ThreadLog as `kind: :policy_result`. The audit story is uniform.

**Composition**: policies are declared per Action. The framework's `PolicyApplier.apply/3` is the single entry point; it's called inside the existing `run_action_async/3` helper that `use Raxol.Agent` injects (`agent.ex` injected helpers section). No change to the author-facing API for invocation.

### 4. `Raxol.Agent.Cache` behaviour (new prerequisite)

Required by `Policy.Cache`. No cache primitive exists in the codebase today; introducing one is a Phase 26 prerequisite, not a separate ADR.

```elixir
@callback get(config(), key()) :: {:ok, value()} | :miss
@callback put(config(), key(), value(), ttl_ms()) :: :ok
@callback delete(config(), key()) :: :ok
@callback flush(config()) :: :ok
```

Two adapters ship: `Cache.Ets` (default, in-process, per-agent table), `Cache.Postgrex` (cross-process, shared via a database row with `expires_at` column).

The Cache is a Phase 26 module but its scope is generic enough that future raxol_core / raxol_payments consumers can use it. Kept under `Raxol.Agent.Cache` namespace initially; promote to `Raxol.Cache` if a non-agent consumer needs it.

### 5. Compose at the applier pipeline

A single pipeline runs for every action invocation:

```
Action invocation request
  ↓
Sandbox check (chain of CommandHooks including Sandbox-derived hooks)
  ↓ (allow)
ThreadLog.append({kind: :directive, payload: request})
  ↓
PolicyApplier.apply(action, params, ctx)
  ↓ Cache check
  ↓ (miss) RateLimit check
  ↓ (allow) Timeout wrap
  ↓ Retry wrap
  ↓ Action.run/2
  ↓
ThreadLog.append({kind: :tool_result | :policy_result, payload: result})
  ↓
Return to caller
```

The pipeline is fail-loud and unidirectional. A Sandbox deny becomes a `:command_denied` message (existing behaviour); a Cache hit short-circuits before the action runs; a RateLimit reject returns `{:error, :rate_limited}`; a Timeout returns `{:error, :timeout}`; Retry exhaustion returns the underlying error.

The pipeline is opt-in: agents that don't declare a `sandbox/0`, `thread_log/0`, or per-action `policies` get the existing behaviour. Migration is per-agent.

### 6. Telemetry

Three new event families:

- `[:raxol, :agent, :sandbox, :denied]`: fires when a Sandbox returns `{:deny, reason}`. Metadata: `agent_id`, `dimension` (`:filesystem | :network | :shell | :send_agent | :resource`), `reason`, `causation_id`.
- `[:raxol, :agent, :thread_log, :appended]`: fires after every ThreadLog write. Metadata: `agent_id`, `kind`, `sequence`. High-volume; consumers should sample.
- `[:raxol, :agent, :policy, :*]`: `:retry_attempt`, `:retry_exhausted`, `:rate_limited`, `:cache_hit`, `:cache_miss`, `:timeout`. Metadata: `agent_id`, `action_name`, `policy_kind`, plus policy-specific fields.

All three event families flow through Phase 24's CloudEvents envelope with `causation_id` chaining. The existing `[:raxol, :agent, :*]` event family is unchanged.

## Consequences

### What becomes possible

- **Multi-dimensional isolation per agent.** A coordinator with `Sandbox.Shell.deny_all()` can dispatch workers each with their own `Sandbox.Filesystem.allowlist/1` to non-overlapping directories. Sandbox dimensions are independent: tightening shell access doesn't restrict file writes, restricting network doesn't affect inter-agent messaging.
- **Durable audit trail per agent.** "What did MyAgent do in the last 24 hours" is now answerable from the ThreadLog without telemetry capture. Cross-session, cross-restart, cross-deployment if Postgrex is configured. Pairs with the operator-flow contract from ADR-0018: a paused run's "what was the agent doing" is now a query.
- **Declarative policies replace ad-hoc patterns.** Retry, timeout, rate-limit, cache become per-Action declarations. The framework guarantees they're applied uniformly. Bugs that come from per-call-site implementations (forgotten backoff, missing timeout on shell-out, cache-key collisions) disappear by construction.
- **MCP-driven agent introspection.** The `agent://<agent_id>/thread` resource (materialized from `ThreadLog`) lets operators using Claude as an MCP client query agent activity directly. ADR-0012's "MCP as rendering target" extends to agents.
- **Foundation for Workflow concurrency in agents.** ADR-0019's parallel branches let a single workflow fan out N sub-tasks. Phase 26 sandboxes give each branch its own isolation surface; Phase 26 ThreadLog gives each branch its own audit slice; Phase 26 policies give each branch its own retry/timeout/rate-limit posture. The three ADRs (0017, 0018, 0019, 0020) compose into a workable substrate.

### What costs we accept

- **The pipeline adds overhead per invocation.** Sandbox check + ThreadLog append + PolicyApplier compose is bounded (each step is microseconds) but it's per-action-call. For agents that invoke actions at high frequency (every keypress in a TUI, every tick in a polling loop), the overhead is measurable. Mitigation: ThreadLog adapters support batching (default Ets adapter flushes appends in batches of 32); Cache hit short-circuits before any further work; Sandbox composes statically at agent startup so the chain is fixed-cost.
- **The author surface grows.** `sandbox/0`, `thread_log/0`, per-Action `policies:` opt are three new things to learn. Mitigation: each is opt-in; defaults are the existing behaviour (no sandbox = `PermissionHook` only; no thread_log = no durable log; no policies = direct `Action.run/2`).
- **`ThreadLog` writes are high-volume.** A chatty agent writes hundreds of events per minute. The Postgrex adapter handles this fine with batching, but operators must plan retention (truncate older sequences periodically). Documented in the Postgrex adapter's moduledoc; not enforced by the runtime.
- **Cache invalidation is the author's responsibility.** `Policy.Cache` keys on `key_fn(params)`; if `params` doesn't capture all the inputs that affect the result, the cache returns stale data. No framework-level invalidation hook because cache invalidation strategies are domain-specific. Documented as a known limit.
- **Sandbox composition order matters.** Authors who declare both `command_hooks/0` (legacy) and `sandbox/0` (new) get the legacy hooks first, then the Sandbox-derived hooks. A legacy hook that calls a Sandbox-blocked operation will still see the operation succeed at the legacy hook level. Document migration: prefer `sandbox/0`; deprecate `command_hooks/0` once parity is reached.
- **`PermissionHook` and `Sandbox` coexist during deprecation.** The five-level mode hierarchy stays for one minor release as an alias; `PermissionHook.read_only()` becomes a constructor on the new Sandbox surface. Deprecation warning fires on direct use.

### What this ADR does not decide

- **Capability tokens.** A future "MyAgent gets one token to write to /workspace/file.txt that expires in 5 minutes" model is real (cf. POSIX capabilities, biscuit-auth). Out of scope here; Sandbox dimensions are coarser than tokens by design.
- **Distributed `ThreadLog`.** The Postgrex adapter gives cross-node visibility, but a sharded multi-write thread log (where every BEAM node writes to its own partition) is out of scope. Single-Postgres-instance is the contract.
- **Policy composition DSL.** Policies are a list of structs in declaration order. A future "policies form a tree with conditional application" syntax is not in scope.
- **MCP tool derivation from Actions.** ADR-0012 made MCP a rendering target from the component tree. Extending it to agent Actions (so every Action becomes a callable MCP tool automatically) is its own ADR; this ADR ships the durable backing (`agent://<agent_id>/thread`) but not the per-Action tool derivation.
- **Audit log retention enforcement.** ThreadLog adapters don't auto-truncate. A future retention policy struct (`Policy.AuditRetention`) could land but isn't in scope.
- **Sandbox enforcement on directives emitted from non-Action paths.** `update/2` callbacks that emit directives outside an Action invocation route through the existing CommandHook chain (which Sandboxes feed). They don't get policy application: Cache, Retry, RateLimit, Timeout are tied to the Action surface, not arbitrary directive emissions. Documented as a deliberate scope boundary.
- **Cross-agent Cache sharing.** `Cache.Ets` is per-agent; `Cache.Postgrex` is per-config (which may be shared). Cross-agent invalidation primitives ("when AgentA writes, AgentB's cache for the same key invalidates") are out of scope.
- **Compile-time sandbox verification.** A future dialyzer-flavored check that "this Action's body cannot escape its declared Sandbox" is interesting but speculative; not in scope.

## Alternatives considered

### Extend `PermissionHook` with more modes

Add `:network_only`, `:filesystem_only`, `:shell_only` etc to the five-level hierarchy.

Rejected. The hierarchy assumes a linear ordering. Adding modes that aren't strict supersets of each other breaks the comparison semantics in `@mode_ranks`. The multi-dimensional Sandbox approach captures the orthogonality correctly.

### Make `Sandbox` an `Allowlist + Denylist` struct, not a behaviour

Replace the per-dimension modules (`Sandbox.Filesystem`, `Sandbox.Network`, etc) with one struct: `%Sandbox{allow: %{filesystem: [...], network: [...]}, deny: %{...}}`.

Rejected. Per-dimension modules let each dimension carry its own validation semantics (`Sandbox.Filesystem` knows how to normalize paths; `Sandbox.Network` knows how to match wildcard hostnames). A flat allowlist/denylist forces the framework to know about path semantics, hostname matching, signal names, and process quotas all in one place. The behavior-per-dimension keeps that knowledge local.

### Put `ThreadLog` in `raxol_core`, not `raxol_agent`

The durable-audit-log primitive is generic. `raxol_payments` could use it for transaction logs; `raxol_acp` for memo dispatch logs.

Rejected for now. The `ThreadLog` is tied to agent semantics (`kind: :tool_call | :tool_result | :message | :summary`): the schema reflects agent activity. A generic durable log (`Raxol.AppendOnlyLog`) could be extracted later if a non-agent consumer needs it, but starting with the agent-specific shape avoids a premature abstraction.

### Make policies first-class graph nodes (like Workflow channels)

`Policy.Retry` becomes a node type in `Raxol.Workflow.Graph`; an Action invocation is wrapped by a sub-graph.

Rejected. Workflow nodes are workflow-runtime concepts; binding agent policies to them creates a coupling that breaks `Action.call/2` calls outside a workflow context (which is most of them). Policies as declarative struct lists per Action keep them composable inside and outside workflows.

### Skip `Cache` and rely on consumer-provided caching

Cache is generic enough that ETS-or-Postgrex layers exist in plenty of consumers; don't ship one.

Rejected. The `Policy.Cache` struct is much more useful with a paired primitive that just works. Authors writing a single agent shouldn't have to bring their own cache library to get TTL semantics. The two adapters (`Cache.Ets`, `Cache.Postgrex`) are ~150 LOC each; the cost is low.

### Defer Phase 26 until a third consumer demands it

Wait for raxol_payments or a future agent to need sandboxing before scoping it.

Rejected. The design memory for the operator-flow / sandbox / audit space is freshest now (ADR-0017, 0018, 0019 all landed in this session). Codifying when context is loaded is cheaper than re-deriving the design later. Implementation can wait; the scope shouldn't.

## Validation

How we know the design is right:

- **Existing tests pass unchanged.** Every test in `packages/raxol_agent/test/` (461 today) runs against the new code without modification. Sandbox/ThreadLog/Policies are opt-in.
- **A reference agent under `packages/raxol_agent/examples/agents/` exercises all three primitives.** Sandbox with three dimensions, ThreadLog with the Ets adapter, an Action with all four Policy types declared. Tests assert: a Sandbox deny produces a `:command_denied` message and a `:sandbox_deny` ThreadLog event; a Cache hit short-circuits the action body and writes a `:cache_hit` event; a Retry attempt produces N `:retry_attempt` events plus one final `:tool_result`.
- **Symphony's RaxolAgent runner stays green.** `packages/raxol_symphony/lib/raxol/symphony/runners/raxol_agent.ex` consumes agents through the existing surface; Phase 26 changes don't break the runner or its 444+ Symphony tests.
- **ThreadLog round-trip:** an agent writes 100 tool calls, restarts, reads them back from `ThreadLog.Ets` (in-process persistence via the Ets table) and `ThreadLog.Dets` (cross-restart). Property test: `list/3` returns exactly what `append/2` wrote, in order, no gaps in `sequence`.
- **Postgrex adapter is opt-in and tested via `:integration` tags (same pattern as `Saver.Postgrex`)**: gated on `RAXOL_AGENT_PG_URL` or `POSTGRES_*` env vars.
- **Policy applier order is property-tested.** Property: applying Policy.Cache + Policy.Retry + Policy.Timeout produces identical outputs across reorderings of the policy list (modulo where caching takes effect). Specific composition order (Cache -> RateLimit -> Timeout -> Retry -> run) is documented and pinned.

## References

- ADR-0012: MCP as Rendering Target (the precedent for "expose runtime state as an MCP resource")
- ADR-0017: Workflow paused-run query (the precedent for "behaviour + adapters" pattern, here applied to ThreadLog)
- ADR-0018: Operator-flow contract (the precedent for "declarative configuration, runtime adapts")
- ADR-0019: Workflow concurrency (the parallel-runtime ADR; this ADR is its agent-side counterpart)
- `packages/raxol_agent/lib/raxol/agent.ex:33-159` (the `use Raxol.Agent` macro and overridable callbacks)
- `packages/raxol_agent/lib/raxol/agent/command_hook.ex:57-75` (CommandHook behaviour; the Sandbox runtime seam)
- `packages/raxol_agent/lib/raxol/agent/permission_hook.ex:8-14, 66-82` (legacy five-level mode hierarchy)
- `packages/raxol_agent/lib/raxol/agent/action.ex:45-51` (`Action.run/2` signature; policies wrap this)
- `packages/raxol_agent/lib/raxol/agent/context_compactor.ex` (the existing ephemeral compaction; ThreadLog records what compaction discards)
- `packages/raxol_agent/lib/raxol/agent/context_store.ex` (ephemeral ETS-backed session state)
- `packages/raxol_symphony/lib/raxol/symphony/runners/raxol_agent.ex:1-114` (Symphony's agent runner; the largest consumer)
- `CLAUDE.md:235` (the REPL sandbox three-level model; influence but not constraint)
