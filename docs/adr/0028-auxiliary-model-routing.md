# ADR-0028: Auxiliary-model routing

## Status

Proposed, 2026-06-18. Hermes-extraction Tier 2 ADR (`~/Desktop/hermes-extraction-report.md`, item
H2.5). Builds on `Raxol.Agent.ExecutorConfig` + `Raxol.Agent.Backend.Selector` and formalizes the
ad-hoc auxiliary-model plumbing already present in ADR-0021's `SelfImprove`/`Curator` and ADR-0022's
`UserModel`.

## Context

Not every model call deserves the frontier model. Compression, titling, triage, decomposition,
curation, profile description, and similar background tasks are cheap work that a small fast model
does well at a fraction of the cost and latency. Raxol already half-knows this: the self-improvement
reviewer (`SelfImprove`), the `Curator`'s consolidation pass, and the dialectic `UserModel` each take
their own `backend`/`model` config so they can run on an auxiliary model. But that wiring is per
feature and ad hoc.

`Raxol.Agent.ExecutorConfig` (`packages/raxol_agent/lib/raxol/agent/executor_config.ex`) plus
`Raxol.Agent.Backend.Selector` (`backend/selector.ex`, `select/1`) pick **one** backend per request.
There is no notion of "this is a curation task, route it to the curation slot's model with that
slot's fallback chain."

Hermes routes eleven auxiliary task slots (compression, title, triage, decomposition, curation,
vision, web-extract, approval-scoring, MCP routing, skills search, profile description), each to its
own provider/model with its own fallback chain. The gap is a multi-slot router that the existing
per-request selection consults by task kind.

## Decision

**Add an `auxiliary:` config map keyed by task kind, and a `Raxol.Agent.Auxiliary` resolver that maps
a task kind to an `ExecutorConfig` (with a fallback chain). The self-improvement, curator, and
user-model features, and any future background task, ask the resolver for their slot's config instead
of carrying their own. A task kind with no configured slot falls back to the default executor, so the
behaviour is unchanged when `auxiliary:` is unset.**

### 1. `auxiliary:` config, keyed by task kind

```elixir
auxiliary: %{
  curation:    %{backend: :anthropic, model: "claude-haiku-4-5", fallback: [:default]},
  user_model:  %{backend: :anthropic, model: "claude-haiku-4-5"},
  title:       %{backend: :openai,    model: "gpt-5-mini"},
  default_aux: %{backend: :anthropic, model: "claude-haiku-4-5"}
}
```

Each slot is an `ExecutorConfig`-shaped map plus an optional `fallback` (an ordered list of other
slot names or `:default`). `default_aux` is the catch-all auxiliary slot; `:default` refers to the
agent's primary executor.

### 2. `Raxol.Agent.Auxiliary.resolve/2`

```elixir
@spec resolve(task_kind :: atom(), keyword()) :: ExecutorConfig.t()
```

`resolve/2` looks up the slot for `task_kind`, returns its `ExecutorConfig`, and threads the slot's
fallback chain so `Backend.Selector.select/1` can try the next slot if a backend is unavailable. A
task kind with no slot resolves to `default_aux`, and with neither, to the agent's primary executor.
So routing is always defined.

### 3. Features ask the resolver, not carry their own config

`SelfImprove`, `Curator` consolidation, and `UserModel` currently take an explicit `backend`/`model`.
They keep that as an override, but when unset they call `Auxiliary.resolve(:curation, opts)` /
`resolve(:user_model, opts)` and use the result. New background tasks (titling, triage, compression)
follow the same pattern with their own task kind. One config surface routes them all.

### 4. Fallback is part of resolution

A slot's `fallback` is an ordered list tried when its primary backend is unavailable (no API key,
provider down). `Auxiliary.resolve/2` returns a chain, and `Backend.Selector` walks it. So a cheap
slot degrades to another cheap slot, and ultimately to `:default`, rather than failing the task.

## Consequences

### Positive

- **Cost and latency drop where quality is not the bottleneck.** Background tasks route to small fast
  models by default instead of the frontier model.
- **One config surface.** Operators tune all auxiliary routing in `auxiliary:` instead of per-feature
  backend keys scattered across `self_improve`, `curator`, and `user_model`.
- **Resilient by construction.** Each slot has a fallback chain, so a missing key or a down provider
  degrades rather than fails.
- **Reuses the existing selection.** `ExecutorConfig` + `Backend.Selector` already pick a backend;
  this adds a per-task-kind lookup in front, not a new selection engine.

### Negative

- **Another config map to get right.** Eleven-ish slots is more surface than one default backend.
- **Routing drift.** A task routed to too weak a model produces worse curation/summaries; the win is
  only real when the slot model is actually good enough for that task.
- **Per-feature overrides plus a router is two ways to set the model**, which can confuse.

### Mitigation

- Ship sensible defaults (every unset slot resolves to `default_aux`, and that to `:default`), so an
  operator can start with one `default_aux` and refine.
- Document which task kinds are quality-sensitive (curation, decomposition) versus
  throughput-sensitive (title, triage) so slots are tuned with intent.
- Make the precedence explicit: an explicit per-feature `backend`/`model` wins over the router, which
  wins over `default_aux`, which wins over `:default`.

### What this ADR does not decide

- **The full eleven Hermes slots.** This ADR defines the router and the slots the existing features
  need (`curation`, `user_model`, plus `default_aux`); other slots (vision, web-extract, MCP routing)
  are added as those features land.
- **Automatic model selection by difficulty.** Routing is by static task kind, not a learned
  difficulty estimate; an adaptive router is future work.
- **Cost accounting.** Tracking spend per slot is a separate concern from routing.

## Alternatives considered

### Keep per-feature `backend`/`model` config

Leave each feature carrying its own auxiliary model. Rejected: it is the status quo, and it scatters
routing across features with no shared fallback and no single place to tune cost.

### One global auxiliary model for all background tasks

A single `aux_model` for everything. Rejected: titling and curation have different quality needs; one
model is either too weak for curation or too expensive for titling. Per-task-kind slots are the point.

### Route by message-size or token heuristics instead of task kind

Pick the model from the request's size. Rejected: task kind is a better signal than size (a short
curation prompt still wants a capable model; a long triage dump does not). Static task-kind slots are
simpler and more predictable; an adaptive router is noted as future work.

## Validation

- **Existing behavior unchanged.** With `auxiliary:` unset, every task kind resolves to the agent's
  primary executor, exactly as today.
- **Resolution test:** `resolve(:curation, ...)` returns the curation slot's `ExecutorConfig`;
  an unknown kind returns `default_aux`; with no `default_aux`, the primary executor.
- **Fallback test:** when a slot's primary backend is unavailable, `Backend.Selector` walks the
  slot's fallback chain and ultimately reaches `:default` rather than failing.
- **Precedence test:** an explicit per-feature `backend`/`model` overrides the router for that
  feature; removing it falls back to the slot.
- **Integration test:** `SelfImprove`/`Curator`/`UserModel` with no explicit backend use the resolved
  auxiliary slot and still produce their effects on a cheap model.

## References

- `~/Desktop/hermes-extraction-report.md` (item H2.5; the eleven Hermes auxiliary slots)
- ADR-0021: Self-improving agents (`SelfImprove` + `Curator`, current ad-hoc aux config)
- ADR-0022: Memory provider stack (`UserModel`'s dialectic aux model)
- `packages/raxol_agent/lib/raxol/agent/executor_config.ex` (`new/1`, `to_backend_opts/1`; the per-request config the router returns)
- `packages/raxol_agent/lib/raxol/agent/backend/selector.ex` (`select/1`, which walks the fallback chain)
