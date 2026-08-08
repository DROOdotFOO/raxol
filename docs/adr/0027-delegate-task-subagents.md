# ADR-0027: `delegate_task` summary-only subagents

## Status

Accepted, 2026-07-22 (implemented in `Raxol.Agent.Actions.Task` via `run_subagent/3`). Originally proposed 2026-06-18.

As built, the shipped Action is narrower than the decision below: it is named
`task` (not `delegate_task`), accepts a single string prompt (no list input,
no `Task.async_stream/3` fan-out), runs a nested `Stream.react` rather than a
transient `Agent.Session` with its own `Conversation.Log`, and blocks the
parent tool loop until the sub-agent finishes. It returns `%{result: content}`
where decision item 2 specified `%{summary: ...}`. The sub-agent's toolset is a
fixed read-only set (`list_dir`, `read_file`, `file_stat`, `grep`, `glob`)
rather than a parent-supplied grant, and recursion is bounded by withholding
the `task` tool itself, so the configurable depth guard of decision item 4 does
not exist. The fan-out and Session-backed variants remain unimplemented design.
Hermes-extraction Tier 2 ADR (`~/Desktop/hermes-extraction-report.md`, item
H2.4). Refines the deferred omnigent T2.1 ("sub-agents are async tools + auto-wake") into a clean
summary-only contract. Builds on `Raxol.Agent.Session`, `Raxol.Agent.Team`, the omnigent item-log
(`Raxol.Agent.Conversation.Log`), and `Raxol.Agent.Turn` (ADR-0021's wiring).

## Context

A parent agent that needs a self-contained piece of work done has two existing options, neither of
which is the right shape. `Raxol.Agent.Team` (`packages/raxol_agent/lib/raxol/agent/team.ex`) is an
OTP supervisor for a long-lived coordinator/worker group. `Directive.SendAgent` routes a message to
another agent via the `Registry`. Both keep the sub-work's intermediate chatter visible and require
the parent to manage the other agent's lifecycle.

Hermes's `delegate_task` is sharper: a subagent gets its own conversation, terminal, and toolset, and
*"only the final summary is returned; intermediate tool results never enter your context window."*
Parallel dispatch is free. The value is twofold: context isolation (the parent's window is not
polluted by the subagent's tool spray) and a clean fan-out primitive (delegate N tasks, collect N
summaries).

## Decision

**Add a `delegate_task` Action that runs a task in a transient `Raxol.Agent.Session` with its own
`Conversation.Log` and toolset, and returns only the subagent's final summary message to the parent.
A list of tasks fans out via `Task.async_stream` for free parallelism. The subagent's intermediate
items stay in its own log and never enter the parent's context.**

### 1. A transient, isolated subagent

`delegate_task` starts a `Raxol.Agent.Session` (`environment: :agent`, the same isolated runtime
Symphony and the agent harness already use) with a fresh `Conversation.Log`, the requested toolset,
and the task prompt. It runs to completion through `Raxol.Agent.Turn`, then the session is torn down.
The subagent is transient: it exists for the one task and is supervised under a `Task.Supervisor` so
a crash never touches the parent.

### 2. Summary-only return

The parent receives only the subagent's **final assistant message**. Every intermediate item
(tool calls, tool results, reasoning) lives in the subagent's `Conversation.Log` and is available for
audit, but is never returned to or counted against the parent's context window. The Action's result
is `{:ok, %{summary: String.t()}}`.

### 3. Parallel fan-out

`delegate_task` accepts either one task or a list. A list runs through `Task.async_stream/3` with
back-pressure (a bounded `max_concurrency`), so a parent delegates N independent tasks and collects N
summaries in one call. Each subagent is isolated, so parallel tasks do not share or corrupt state.

### 4. Bounded toolset and depth

A delegated subagent gets the toolset the parent grants it, not the parent's full set by default. A
depth guard caps delegation chains: a subagent may itself delegate only up to a configured depth,
bounding a fan-out explosion. `delegate_task` flows through the same Authorization seams (ADR-0020),
so a consumer can gate delegation to ASK or DENY.

## Consequences

### Positive

- **Context isolation.** The parent's window stays clean; a subagent that makes fifty tool calls
  returns one summary, not fifty results.
- **A free fan-out primitive.** `Task.async_stream` turns "delegate these N things" into one call
  with bounded concurrency and back-pressure, the BEAM-native version of Hermes's parallel dispatch.
- **Reuses the isolated session.** `Agent.Session` already runs an agent in `:agent` environment with
  its own log; this wraps it as a tool rather than inventing a new runtime.
- **Crash-isolated.** A subagent under a `Task.Supervisor` cannot take down the parent.

### Negative

- **Summary-only loses detail by design.** If the parent needed an intermediate result, it must ask
  the subagent for it explicitly; the default discards intermediates.
- **Cost multiplies.** N parallel subagents are N model conversations; fan-out is cheap in code but
  not in tokens.
- **Depth and toolset must be bounded** or a delegation chain can explode.

### Mitigation

- The subagent's full `Conversation.Log` is retained for audit (and searchable via `session_search`,
  ADR-0022), so detail is recoverable even though it is not returned.
- Cap `max_concurrency` and total subagents per parent turn; record fan-out to the `ThreadLog`.
- Default the delegation depth to a small number and the subagent toolset to an explicit grant, not
  inheritance.

### What this ADR does not decide

- **Auto-wake / async-tool semantics.** The omnigent T2.1 idea of a subagent that pauses and wakes
  the parent later is deferred; `delegate_task` is synchronous-with-parallelism (the Action returns
  when the summaries are ready), which covers the common case without the auto-wake machinery.
- **Cross-node delegation.** Single-node `Task.async_stream` only; delegating to agents on other
  BEAM nodes (via the swarm layer) is future work.
- **Shared memory between subagents.** Each subagent is isolated; a shared scratch space across a
  fan-out is out of scope.

## Alternatives considered

### Use `Agent.Team` directly

Expose the existing coordinator/worker supervisor as the delegation tool. Rejected: `Team` is for
long-lived groups with persistent membership; a delegated task is transient and summary-only. Wrapping
`Team` would carry lifecycle the task does not need.

### Return the full subagent transcript

Give the parent everything the subagent did. Rejected: that defeats the point. The context isolation
(intermediates never enter the parent's window) is the feature, not a limitation; the transcript stays
in the subagent's log for audit.

### Message-passing via `Directive.SendAgent`

Route the task to a pre-existing agent and await a reply. Rejected: that requires the parent to manage
the other agent's lifecycle and offers no isolation or fan-out. `delegate_task` owns the transient
session and the parallel dispatch.

## Validation

- **Existing behavior unchanged.** With no `delegate_task` Action exposed, `Team` and `SendAgent`
  behave exactly as today.
- **Isolation test:** a subagent that makes several tool calls returns only its final summary; the
  parent's recorded conversation contains the summary and none of the subagent's intermediate items.
- **Fan-out test:** a list of N tasks returns N summaries; the subagents run concurrently (bounded by
  `max_concurrency`) and do not share state.
- **Crash-isolation test:** a subagent that crashes returns an error for that task only; the parent
  and sibling subagents are unaffected.
- **Depth-guard test:** a subagent delegating past the configured depth is denied; the chain does not
  explode.
- **Audit test:** the subagent's full transcript is retained in its `Conversation.Log` and is
  findable via `session_search` even though it was not returned.

## References

- `~/Desktop/hermes-extraction-report.md` (item H2.4; Hermes `delegate_task`, summary-only contract)
- ADR-0021 / ADR-0022: skills + memory (the subagent's log feeds `session_search`)
- ADR-0020: Agent Sandbox, ThreadLog, declarative Policies (delegation flows through the same gating)
- `packages/raxol_agent/lib/raxol/agent/actions/task.ex` (the shipped Action: `Delegate` +
  `run_subagent/3`, a nested `Raxol.Agent.Stream.react/2` run inheriting only `:cwd` and `:jail`)
- `packages/raxol_agent/lib/raxol/agent/session.ex` (`start_link/1`, the transient isolated subagent
  this ADR proposed and the shipped Action does not use)
- `packages/raxol_agent/lib/raxol/agent/team.ex` (the long-lived alternative this ADR rejects)
- `packages/raxol_agent/lib/raxol/agent/turn.ex` (the turn driver the proposed subagent would run
  through)
- `packages/raxol_agent/lib/raxol/agent/conversation/log.ex` (the proposed subagent's isolated
  history)
