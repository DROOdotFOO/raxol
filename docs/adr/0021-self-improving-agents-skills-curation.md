# ADR-0021: Self-improving agents: runtime skills + background curation

## Status

Accepted, 2026-07-22 (implemented in `Raxol.Agent.SelfImprove`, `Raxol.Agent.Curator`, and `Raxol.Agent.Skills.Store`). Originally proposed 2026-06-17. First of the Hermes-extraction Tier 1 ADRs (research deliverable at
`~/Desktop/hermes-extraction-report.md`, items H1.1 self-improvement loop + H1.2 runtime skill
authoring). Hermes (Nous Research) is the benchmark agent this work targets: its defining claim,
"an agent that gets more capable the longer it runs," rests on agent-authored skills plus an
after-turn background curation pass plus a Curator that ages and consolidates those artifacts.
This ADR scopes the Raxol counterpart.

Revised 2026-06-17 after a second Hermes research pass against current sources (v0.14-v0.16 official
docs + the `NousResearch/hermes-agent` repo). The design held up (every curator threshold below
matches Hermes verbatim) and the pass added concrete buffer caps plus a deferred-first-pass
mitigation drawn from a real Hermes curator incident (issue #18373).

Builds on ADR-0020 (Sandbox / ThreadLog / declarative Policies: the `CommandHook` chain and the
`ThreadLog` audit seam are reused here, not re-invented) and on the omnigent item-log
(`Raxol.Agent.Conversation.{Item,Store,Log}`, the after-turn data source). Companion ADRs to
follow: H1.3 (memory-provider abstraction + full-text recall + dialectic user modeling) and H1.4
(unified messaging gateway).

## Context

The agent stack is feature-complete for the prompt-then-react loop. `use Raxol.Agent`
(`packages/raxol_agent/lib/raxol/agent.ex:33-159`) gives an author overridable callbacks including
`available_actions/0`, `memory_provider/0`, `command_hooks/0`, `compaction_config/0`, and
`thread_log/0`. `Raxol.Agent.Stream.react/2` (`stream.ex:140`) runs the framework-owned ReAct loop;
`Raxol.Agent.Conversation.Recorder.record_stream/4` (`conversation/recorder.ex:43`) drains that
stream into the durable item-log. Cross-session memory exists as a behaviour
(`memory.ex:33-38`: `prefetch/2`, `search/2`, `store/2`, `forget/2`, `build_system_prompt/1`) with
an ETS adapter doing BM25-lite ranking over an inverted token index, plus three LLM-callable
Actions (`actions/memory/{remember,recall,forget}.ex`). Commit `3ed30eab` just landed
`Raxol.Core.Stores.Dets` (`packages/raxol_core/lib/raxol/core/stores/dets.ex`) to DRY up
ETS+DETS-backed stores.

Three structural gaps separate this from "gets more capable the longer it runs."

### Gap 1: No procedural memory

Raxol has *episodic* memory (Conversation.Log: what happened) and *semantic* memory
(Memory.Record: facts the agent chose to keep). It has no *procedural* memory: a reusable,
named, parameterized "how to do X" that the agent can read on demand and, crucially, **author and
refine itself**. Skills today are static prose loaded out-of-band; the only skill code in the
repo is `RaxolPlaygroundWeb.SkillController`, a static file server for one `skill.md`. An agent
that solves a hard multi-step task cannot capture the working procedure for next time. Hermes
treats skills as writable procedural memory (`skill_manage` create/patch/edit, progressive
disclosure `skills_list` -> `skill_view(name)` -> `skill_view(name, path)`) on the
agentskills.io `SKILL.md` standard. Raxol's entire skill ecosystem (`~/.agents/skills`) is already
on that standard, so the missing piece is a runtime, not a format.

### Gap 2: No self-improvement loop

The only path to durable knowledge today is an explicit `memory_remember` tool call **during** the
turn. That competes with the user's task for the model's attention and token budget, and it never
fires unless the model thinks to call it mid-flight. There is no after-the-fact pass that reviews a
completed turn and decides what was worth keeping. Hermes forks a background `AIAgent` after a turn
(its own prompt cache, never touching the live conversation) precisely so curation does not steal
the foreground turn's latency or context. Raxol has the ingredients (the completed turn is already
in `Conversation.Log`; spawning an isolated reviewer is a one-line `Task` on the BEAM) but no wiring.

### Gap 3: No artifact hygiene

Even granted Gaps 1 and 2, accumulated skills and memories degrade recall as they grow: stale
procedures mislead, near-duplicates dilute ranking, dead skills inflate the `skills_list` token
cost. Hermes runs a Curator on an interval-plus-idle gate that ages skills
`active -> stale (30d unused) -> archived (90d unused)`, optionally consolidates near-duplicates
with an LLM pass, and keeps tarball backups for rollback. Raxol has no equivalent; without it, the
self-improvement loop would be a memory leak with good intentions.

## Decision

**Add a procedural-memory subsystem, an after-turn background self-improvement task, and a Curator,
all in `raxol_agent`, filesystem-backed on the agentskills.io `SKILL.md` standard. All three are
opt-in; an agent that declares no skills provider and no self-improvement config keeps today's
behaviour exactly.**

### 1. Skills as filesystem `SKILL.md`, not modules or DB rows

A skill is a directory on disk, not a compiled module and not a database row:

```
<skills_root>/<category>/<name>/
  SKILL.md            # required: YAML frontmatter + markdown body
  references/ templates/ scripts/ assets/   # optional supporting files
```

`skills_root` defaults to `~/.raxol/skills/`; `external_dirs` (default `["~/.agents/skills"]`)
are read so an agent immediately sees the user's existing skill library. Three modules:

- `Raxol.Agent.Skill`: pure parse/render of frontmatter (`name`, `description`, `version`,
  `metadata`, `created_by`) plus body; no process.
- `Raxol.Agent.Skills.Store`: a `BaseManager` GenServer owning a skill index and per-skill usage
  telemetry, persisted via `Raxol.Core.Stores.Dets`. Disk is the source of truth; the store is a
  warm index over it.
- Progressive disclosure is a property of the read API, not a new mechanism: list returns metadata
  only, view returns one file.

### 2. Three skill Actions, exposed through `available_actions/0`

| Action | Tool name | Shape |
| --- | --- | --- |
| `Skills.List` | `skills_list` | `() -> [%{name, category, description, state}]` (metadata only, the cheap level) |
| `Skills.View` | `skill_view` | `(name, path \| nil) -> SKILL.md body or one supporting file` |
| `Skills.Manage` | `skill_manage` | `(action: :create\|:patch\|:edit\|:delete, name, ...) -> %{ok}` |

These are ordinary `Raxol.Agent.Action`s (`action.ex:51` `run/2`, `action.ex:62` `__using__`), so
they ride the existing `ToolConverter` dispatch and need no new tool plumbing. They are added to an
agent's tool set only when the agent declares a skills provider, mirroring how memory Actions
appear only when `memory_provider/0` is set.

### 3. The self-improvement loop is an after-turn background `Task`

When a turn completes, the framework may spawn one linked, isolated `Task` that reviews the turn and
persists durable knowledge. It attaches at the existing seam: right after
`Recorder.record_stream/4` (`conversation/recorder.ex:43`) finishes draining a `react/2` turn into
the log.

```
react/2 turn completes
  -> Recorder.record_stream drains items into Conversation.Log   (existing)
  -> if self_improve enabled and turn qualifies:
       Task.start_link(fn ->
         items = Conversation.Log.items(log, conv_id, after: turn_start_seq)
         reviewer runs on an AUXILIARY (cheap) model, read-only over `items`
         may: Memory.store(record)            # semantic
              Skills.Store create/patch        # procedural, created_by: :agent
       end)                                    # never mutates live agent state
```

The reviewer is a separate model call with its own prompt; it cannot alter the live conversation or
agent state, only append to memory and the skill store. It is **triggered**, not run every turn:
gate on turn success and complexity (default: at least `min_tool_calls: 5`), debounced per agent.
Artifacts it writes are tagged `created_by: :agent`. Foreground `skill_manage` calls stay
user-directed and are tagged `created_by: :user` (this distinction matters for the Curator, item 5).

### 4. Bounded agent-curated memory buffers

Alongside the existing ranked Memory store, the system prompt carries two small, agent-curated
buffers in the Hermes idiom: an environment/conventions buffer and a user-profile buffer (Hermes caps
these at roughly 2,200 and 1,375 chars respectively), injected as a frozen snapshot at session start
(after any static system messages, preserving the cacheable prefix, exactly as
`Memory.Manager.enrich_messages/3` already does, and the same frozen-snapshot mechanism Hermes
relies on to keep these buffers cacheable). Writes use
**overflow-error-no-autocompact** semantics: when a write would exceed the buffer's char budget,
the store returns an error listing current entries and the agent must consolidate or remove in the
same turn. This is deliberate (matching Hermes): silent auto-compaction loses the agent's
intent about what to keep. The richer memory story (a provider abstraction with multiple backends,
full-text `session_search`, and dialectic user modeling) is **H1.3 and out of scope here**; this
ADR only adds the write-from-curation path and the two bounded buffers.

### 5. The Curator (`BaseManager` GenServer)

A supervised GenServer that keeps agent-authored artifacts healthy. Two phases:

- **Phase A (deterministic, no model):** a lifecycle state machine over skill usage telemetry,
  `active -> stale (default 30d unused) -> archived (default 90d unused)`. Archived skills move to
  an `.archive/` dir and drop out of `skills_list`. Pinned skills bypass all transitions.
- **Phase B (opt-in, model-driven):** a consolidation pass (`consolidate: false` by default) that
  inspects near-duplicate or overlapping skills via `skill_view` and proposes keep / patch /
  merge / archive, on an auxiliary model.

Gating is interval-plus-idle, checked at startup and on a periodic tick (OTP timer), **not cron**:
run only when `interval_hours` (default 168) has elapsed AND the agent has been idle for
`min_idle_hours` (default 2). Before any real pass, a tarball backup is written to a backups dir
(keep N); `rollback` restores the latest. The Curator only ever touches `created_by: :agent`
artifacts, so a user's hand-authored skills are never aged or rewritten.

### 6. Trust, isolation, and audit reuse ADR-0020

Skill and memory writes are effects, so they flow through the existing `CommandHook` chain
(`command_hook.ex:63` `pre_execute`, `:86` `run_pre_hooks`) and are recorded to the `ThreadLog`
under a new `kind: :skill_write` (and `:memory_write`). The background reviewer and the Curator run
under a read-mostly Sandbox (ADR-0020) whose only write dimension is the skills/memory roots; they
cannot shell out or reach the network. When an agent is configured with an Authorization policy
(ADR-0020 / the ALLOW/ASK/DENY engine), `skill_manage` and curation writes can be gated to ASK.

### 7. Supervision and new callbacks

`Raxol.Agent.Skills.Store` and `Raxol.Agent.Curator` are added as siblings in
`Raxol.Agent.Supervisor` (`supervisor.ex:24-31`, `:rest_for_one`), started only when configured,
exactly like `memory_children/0` (`supervisor.ex:35`) gates the memory store today. Two new
overridable, default-off agent callbacks:

```elixir
@callback skills_provider() :: {module(), keyword()} | nil          # default: nil
@callback self_improve() :: %{enabled: boolean(), model: term(),    # default: nil
                              min_tool_calls: pos_integer()} | nil
```

## Consequences

### Positive

- **Agents accumulate procedural skill, not just facts.** A solved hard task becomes a reusable,
  inspectable `SKILL.md` that the same agent (or another) reads next time. This is the concrete
  mechanism behind "more capable the longer it runs."
- **Zero-format-cost interop.** Because skills are agentskills.io `SKILL.md` on disk, the user's
  existing `~/.agents/skills` library is readable on day one, and agent-authored skills are
  git-trackable, human-editable, and portable to Hermes/Claude/Cursor without translation.
- **Curation never taxes the foreground turn.** The reviewer is an isolated background `Task` on a
  cheap model; the user-facing turn keeps its full latency and context budget. This is strictly
  cleaner on the BEAM than Hermes's forked-process prompt-cache juggling.
- **Bounded growth by construction.** The Curator ages and consolidates agent-authored artifacts;
  recall quality does not silently decay as the library grows.
- **Audit and isolation come for free.** Reusing the ADR-0020 `CommandHook` + `ThreadLog` +
  `Sandbox` seams means every skill/memory write is logged and policy-gated with no new machinery.

### Negative

- **A background model call per qualifying turn costs tokens and money.** Curation is not free even
  on a cheap model.
- **Author surface grows by two callbacks** (`skills_provider/0`, `self_improve/0`) plus three new
  tools in the agent's tool set.
- **Disk is now agent-writable state.** Agent-authored files under `skills_root` are a new mutable
  surface with its own failure and security considerations (a poisoned skill is a prompt-injection
  vector on the next read).
- **A bad auto-authored skill can mislead future turns** until the Curator ages it out or a human
  edits it.

### Mitigation

- Gate the reviewer on success + `min_tool_calls` + per-agent debounce, and route it to an
  auxiliary model; make the whole loop opt-in and off by default.
- Keep both callbacks defaulting to `nil`; an agent that ignores them behaves exactly as today.
- Run the reviewer and Curator under a write-only-to-skills-dir Sandbox; scan `SKILL.md` content
  for prompt-injection on read (same scanner H3.3 will introduce for context files); record every
  write to the ThreadLog.
- Tarball backups + `rollback`, plus `created_by: :agent` tagging so curation can never touch
  human-authored skills, bound the blast radius of a bad write.
- Defer the first curator pass a full `interval_hours` after install and offer a `--dry-run` preview.
  Hermes shipped exactly this after its own curator auto-archived user-authored skills (issue #18373);
  the `created_by: :agent`-only rule already prevents that failure mode here, but the deferred first
  pass is cheap defense-in-depth against a misclassified skill.

### What this ADR does not decide

- **The memory-provider abstraction, full-text `session_search`, and dialectic user modeling** are
  H1.3, a separate ADR. Here, memory is the existing behaviour plus the two bounded buffers.
- **A skill hub / install / remote sources** (Hermes's taps). Out of scope; local + `external_dirs`
  only.
- **Skill bundles** (grouping skills behind one slash command). Deferred.
- **Cross-agent skill sharing or a fleet-wide skill registry.** Single-node, per-skills-root only.
- **A trajectory-export / RL pipeline** (Hermes's Atropos loop, report H3.4). The self-improvement
  here is runtime artifact accumulation, not model training.

## Alternatives considered

### Skills as compiled Elixir modules

Generate and `Code.compile_string/2` a module per skill so a skill is callable Elixir.

Rejected. Skills must be authorable by a model and a human at runtime; compiling agent-written code
is a code-execution and hot-reload hazard, loses agentskills.io interop, and makes a skill a binary
artifact rather than inspectable prose. Procedures are prose the model reads, not functions it links.

### Skills as database rows

Store `SKILL.md` content in Postgres/ETS keyed by name.

Rejected. Breaks git-trackability and the agentskills.io filesystem contract, requires a DB for a
feature that should work on a `$5 VPS`, and gains nothing: the Store already indexes disk via
`Core.Stores.Dets`.

### Synchronous in-turn curation

Have the foreground model decide, at end of turn, what to persist, in the same loop.

Rejected. It steals the user-facing turn's latency and token budget and couples curation quality to
the foreground model's remaining attention. Hermes deliberately forks; the isolated background Task
is the BEAM-native version of that decision.

### Cron-driven Curator

Schedule the Curator on a fixed cron tick.

Rejected. Idle-gating matters: consolidating skills while the agent is mid-session churns artifacts
it is actively using. Interval-plus-idle (checked at startup and on an OTP timer) is the Hermes
model and needs no cron subsystem. (A general user-facing `cronjob` tool is report item H2.2, a
different feature.)

### Put Skills / Curator in `raxol_core`

The "named procedure store + lifecycle" shape is arguably generic.

Rejected for now. The reviewer's semantics (what counts as a qualifying turn, `created_by: :agent`
tagging, memory write-back) are agent-specific. Extract a generic store later if a non-agent
consumer appears, mirroring the ADR-0020 decision to keep `ThreadLog` in `raxol_agent`.

## Validation

- **Existing tests pass unchanged.** Skills, self-improvement, and the Curator are opt-in; every
  current `packages/raxol_agent/test/` test runs without modification.
- **Interop test:** `skill_view` reads an existing `~/.agents/skills/<name>/SKILL.md` byte-for-byte
  unchanged; `Raxol.Agent.Skill` round-trips parse -> render with no frontmatter drift.
- **Loop isolation test:** a turn that triggers the reviewer produces a `:skill_write` ThreadLog
  event and a new `created_by: :agent` skill on disk, while the live agent state and conversation
  are provably unchanged (the reviewer ran in a separate process with no `update/2` call).
- **Curator lifecycle property test:** a skill with telemetry crosses `active -> stale -> archived`
  at the configured thresholds; pinned skills never transition; `rollback` restores the
  pre-pass tarball exactly.
- **Overflow semantics test:** a buffer write past the char budget returns an error listing entries
  and does not silently truncate.
- **End-to-end "more capable" test:** run an agent over a multi-step task so a skill is authored,
  restart the process, and confirm the agent both recalls a memory record and reads the
  authored skill on a follow-up task.
- **Symphony stays green:** `packages/raxol_symphony/lib/raxol/symphony/runners/raxol_agent.ex`
  consumes agents through the unchanged surface; its tests do not break.

## References

- `~/Desktop/hermes-extraction-report.md` (items H1.1, H1.2; the Hermes mechanism this mirrors)
- ADR-0020: Agent Sandbox, ThreadLog, declarative Policies (the `CommandHook` + `ThreadLog` +
  `Sandbox` seams reused for audit and isolation)
- ADR-0012: MCP as Rendering Target (the "expose runtime state as an MCP resource" precedent; a
  future `agent://<id>/skills` resource)
- `packages/raxol_agent/lib/raxol/agent.ex:33-159` (the `use Raxol.Agent` callbacks; where
  `skills_provider/0` + `self_improve/0` are added)
- `packages/raxol_agent/lib/raxol/agent/stream.ex:140` (`react/2`, the framework-owned turn loop)
- `packages/raxol_agent/lib/raxol/agent/conversation/recorder.ex:43` (`record_stream/4`, the
  after-turn attach point for the reviewer)
- `packages/raxol_agent/lib/raxol/agent/conversation/log.ex:55-79` (`append`/`subscribe`/`items`,
  the reviewer's read source)
- `packages/raxol_agent/lib/raxol/agent/memory.ex:33-38` (the Memory behaviour; the curation
  write-back target)
- `packages/raxol_agent/lib/raxol/agent/action.ex:51,62` (`run/2` callback + `__using__`; the three
  skill Actions are ordinary Actions)
- `packages/raxol_agent/lib/raxol/agent/command_hook.ex:63,71,86,126` (the hook chain skill/memory
  writes flow through)
- `packages/raxol_agent/lib/raxol/agent/supervisor.ex:24-35` (`:rest_for_one` children +
  `memory_children/0`, the pattern for adding Skills.Store + Curator)
- `packages/raxol_core/lib/raxol/core/stores/dets.ex` (the ETS+DETS helper the Skills.Store and
  usage telemetry reuse; landed commit `3ed30eab`)
