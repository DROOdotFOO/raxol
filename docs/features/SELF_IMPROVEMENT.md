# Self-Improvement

An agent that gets more capable the longer it runs. After a successful turn, a background
reviewer studies what the agent did on a cheap auxiliary model and writes durable takeaways:
facts appended to memory and reusable skills authored as `SKILL.md` files. A Curator then
ages those agent-authored skills over time, keeping the useful ones and archiving the stale
ones, with tar.gz backup and rollback.

The whole loop is OTP-shaped: the reviewer runs in an unlinked `Task` (a crash is logged,
never propagated to the turn), the skills index is a supervised GenServer backed by on-disk
`SKILL.md` files plus DETS telemetry, and every Curator pass is reversible. There is no
single-process store of record to lose.

Skills interoperate with the [agentskills.io](https://agentskills.io) `SKILL.md` format, so
an agent's authored skills sit alongside the ones under `~/.agents/skills`.

## Enabling it

Two `use Raxol.Agent` callbacks turn it on, both opt-in (default off):

```elixir
defmodule MyAgent do
  use Raxol.Agent

  # Procedural memory: exposes skills_list / skill_view / skill_manage as tools.
  def skills_provider, do: Raxol.Agent.Skills.Store

  # After-turn self-improvement on a cheap auxiliary model.
  def self_improve do
    %{enabled: true, model: "claude-haiku-4-5", min_tool_calls: 5}
  end
end
```

Bring up the store and Curator under supervision through app config:

```elixir
config :raxol_agent,
  skills_provider: Raxol.Agent.Skills.Store,
  skills_root: "~/.raxol/skills",
  curator: [skills: {Raxol.Agent.Skills.Store, []}]   # keyword list including :skills
```

The self-improvement side effect fires automatically when a turn is driven through
[`Raxol.Agent.Turn`](AGENT_FRAMEWORK.md#turn-driver). A runtime that drives `Stream.react/2`
directly must call `SelfImprove.after_turn/3` itself; it is a seam, not magic.

## The after-turn loop

`Raxol.Agent.SelfImprove` reviews a completed turn and appends what it learned.

- `after_turn(items, writers, config)` gates on success and `min_tool_calls` (default 5),
  then spawns an unlinked review `Task`. Returns `:spawned` or `:skipped`.
- The reviewer formats the turn, calls the auxiliary model, parses a
  `{memories, skills}` result (tolerating code-fenced JSON), then writes each memory to the
  configured memory provider and each skill to the store tagged `created_by: :agent`.
- The reviewer can only append to memory and the skill store. It never calls `update/2`,
  never touches the live conversation, and its crash is caught and logged.

With no `:backend`/`:model` set and no auxiliary slot configured, review routes through
`Raxol.Agent.Auxiliary` and degrades to the Mock backend (a no-op). See
[auxiliary-model routing](AGENT_FRAMEWORK.md).

## Skills

`Raxol.Agent.Skill` parses and renders the `SKILL.md` format: YAML frontmatter plus a
markdown body. Modeled frontmatter keys are `name` (required), `description`, `version`,
`category`, and `created_by`; any other keys are preserved under `metadata`, so a round trip
never drops a third-party field. Nothing on the wire is turned into an atom.

`Raxol.Agent.Skills.Store` is the warm index (a `BaseManager` GenServer):

- **Managed root** (writable, default `~/.raxol/skills`): skills the agent or user author.
- **External dirs** (read-only, default `~/.agents/skills`): shared skills, scanned for
  `**/SKILL.md`. A managed skill wins over an external one of the same name.
- **Telemetry** (persisted to DETS, replayed into ETS on boot): `use_count`, `view_count`,
  `last_used_at`, `created_at`, `state`, `pinned`. Skill content is re-read from disk every
  boot, so disk is the source of truth and stale content cannot outlive its file.
- A supporting-file read through `skill_view` is path-guarded: absolute paths and `..` are
  rejected, so a read cannot escape the skill directory.

Three tools let the LLM work with skills:

| Tool | Input | Returns |
|------|-------|---------|
| `skills_list` | none | skill metadata only (the cheap disclosure level) |
| `skill_view` | `name`, optional `path` | the `SKILL.md` body, or one supporting file |
| `skill_manage` | `action` (`create`/`patch`/`edit`/`delete`), `name`, fields | `ok`, `name` |

Foreground `skill_manage` creates are tagged `created_by: :user`; the background reviewer's
are tagged `created_by: :agent`. Only that provenance difference makes a skill eligible for
curation.

## Curator

`Raxol.Agent.Curator` ages agent-authored skills so the library does not accumulate cruft.

- **Lifecycle**: `active -> stale -> archived`, measured from a skill's last use. Defaults:
  stale after 30 idle days, archived after 90.
- **Curatable** means `created_by: :agent` and managed and not pinned. User-authored,
  external, and pinned skills are never aged or rewritten.
- **Gating**: a scheduled pass runs at most every 168 hours (7 days) and only after at least
  2 idle hours; the first pass is deferred a full interval. The runtime resets the idle
  clock with `note_activity/1`.
- **Backup and rollback**: before any non-dry-run pass, the Curator writes a compressed
  tarball of the skills root and keeps the newest 5. `rollback/0` restores the latest and
  reloads the store, so a bad aging pass is reversible.
- `run(dry_run: true)` and `plan/0` compute what a pass would do without touching anything.

Consolidation (model-driven merge of near-duplicate skills) is opt-in and not yet
implemented.

## What supervision buys

Three properties fall out of running the loop on OTP rather than in-process:

- The reviewer is an isolated, unlinked `Task`. A model error or parse failure is logged and
  the turn is unaffected.
- The durable substrate is on-disk `SKILL.md` files plus DETS telemetry, separated from the
  warm ETS index. A crash of the store or Curator loses no skill content and no telemetry,
  and the supervisor restarts the manager.
- Every Curator mutation is preceded by a backup and is reversible.

## See also

- [Memory](MEMORY.md): the recall layer the reviewer writes facts into.
- [Agent Framework](AGENT_FRAMEWORK.md): the Turn driver that wires self-improvement into a
  turn, and auxiliary-model routing.
- [Why Raxol](../WHY_RAXOL.md): how this loop compares to the Python agent stacks.
