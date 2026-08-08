# ADR-0025: Cronjob scheduled-task tool

## Status

Accepted; implemented 2026-07-26 (`Raxol.Agent.Scheduler` + `Raxol.Agent.Schedule` in PR #723,
the `cronjob` Action + `Scheduler.Fire`/`Scheduler.Delivery` in PR #725). As built, a fire runs
`Raxol.Agent.Stream.react/2` directly; the `Raxol.Agent.Turn` driver named in decision item 4 is
not on the path. Originally proposed
2026-06-18. Hermes-extraction Tier 2 ADR (`~/Desktop/hermes-extraction-report.md`, item
H2.2). Builds on the agent skill runtime (ADR-0021), the unified messaging gateway (ADR-0023, for
delivery), and `Raxol.Core.Stores.Dets` (the shared ETS+DETS store).

## Context

Raxol can schedule one thing: `Raxol.Symphony.Orchestrator` polls a tracker on a fixed cadence to
claim issues. That is a fixed internal loop, not a user-facing scheduled-task capability. An agent
cannot say "every weekday at 9am, summarize my open PRs and send it to Telegram."

Hermes exposes a first-class `cronjob` tool (`create`/`list`/`update`/`pause`/`resume`/`run`/
`remove`) with four schedule formats: relative (`30m`), interval (`every 2h`), 5-field cron, and an
ISO timestamp. Each fire spins up a fresh agent with no history, injects the job's attached skills,
runs the prompt, and delivers the result to a target (`telegram:-100...`, `discord:#chan`). A
recursion guard disables cron inside a cron run, so a scheduled agent cannot schedule more work.

The gap is a general scheduler plus the tool surface. Note this is a Raxol-agent capability and is
unrelated to the Claude Code harness `Cron*` tools.

## Decision

**Add a `Raxol.Agent.Scheduler` (a `BaseManager` GenServer) backed by a persisted job store, and a
`cronjob` Action over it. Each fire runs a fresh, history-free agent with the job's skills, then
delivers through the gateway. Cron is disabled inside a cron run. The whole subsystem is opt-in.**

### 1. `Raxol.Agent.Scheduler`

A `BaseManager` GenServer holding the active jobs and one `Process.send_after/3` timer per job. On
fire it reschedules the next occurrence (for recurring schedules) and dispatches the run. Jobs
persist to `Raxol.Core.Stores.Dets` so they survive a restart; on boot the scheduler replays the
store and arms timers from each job's next-fire time. Timers, not cron daemons: the BEAM owns the
scheduling.

### 2. Four schedule formats, one parser

`Raxol.Agent.Schedule.parse/1` accepts relative (`"30m"`), interval (`"every 2h"`), 5-field cron
(`"0 9 * * 1-5"`), and ISO 8601 timestamps, and produces a `next_fire/2` function. A timestamp job
is one-shot (no reschedule); the others recur.

### 3. The `cronjob` Action

A single Action with an `action` field (`create`/`list`/`update`/`pause`/`resume`/`run`/`remove`)
reaching the scheduler via `context[:scheduler]`, mirroring how the skill and memory actions reach
their stores. A job carries `prompt`, `schedule`, `skills` (names to inject), `target` (a gateway
route string), and `enabled`.

### 4. Fresh agent per fire, skills injected

Each fire starts a transient agent with **no conversation history**, injects the job's attached
skills (read from the `Skills.Store`, ADR-0021), runs the prompt through `Raxol.Agent.Turn`, and
delivers the final message to the job's target. History-free keeps a daily job from accumulating
context across fires; injected skills give it the procedures it needs.

### 5. Recursion guard

The run context carries an `in_cron` flag. When set, the `cronjob` Action's `create`/`run` paths
return an error, so a scheduled agent cannot schedule or trigger more cron work. This bounds a
runaway scheduling loop.

### 6. Delivery through the gateway

The job `target` is a gateway route string (`"telegram:-100..."`, `"discord:#chan"`). Delivery uses
the `Raxol.Gateway` delivery path (ADR-0023). When the gateway is absent, a job may target a local
callback instead; cron does not hard-depend on the gateway.

## Consequences

### Positive

- **General scheduled automation.** Any agent task becomes a recurring or one-shot job, not just
  Symphony's fixed tracker poll.
- **BEAM-native scheduling.** `Process.send_after` timers plus a persisted job store need no cron
  daemon or external scheduler; jobs survive restarts by replaying the store.
- **History-free fires stay cheap and predictable.** A daily job does not drift as context piles up;
  injected skills supply the needed procedures.
- **Bounded by construction.** The recursion guard stops scheduled agents from spawning more
  scheduled work.

### Negative

- **A new persisted, agent-writable surface.** Jobs are durable state an agent can create; a bad job
  fires on a schedule until paused or removed.
- **Delivery coupling.** Useful targets assume the gateway (ADR-0023); without it, delivery is
  local-only.
- **Schedule-parsing breadth.** Four formats is four parsers to get right, including cron-field edge
  cases.

### Mitigation

- Cap jobs per owner, require an explicit `enabled` to fire, and record every fire to the
  `ThreadLog` (ADR-0020).
- Make the gateway an optional delivery path with a local-callback fallback.
- Reuse a well-tested cron-field parser rather than hand-rolling the 5-field grammar.

### What this ADR does not decide

- **A distributed scheduler across BEAM nodes.** Single-node timers only; a clustered scheduler
  (jobs sharded via the swarm layer) is future work.
- **Sub-minute precision or exactly-once delivery.** Timers are best-effort; a missed fire during a
  restart is re-armed from next-fire time, not back-filled.
- **A UI for managing jobs.** The tool surface is the `cronjob` Action; a dashboard is separate.

## Alternatives considered

### Reuse the Symphony orchestrator loop

Extend Symphony's polling to run user jobs. Rejected: Symphony's loop is tracker-issue-shaped
(claim, isolate, run to terminal state), not a general scheduler. A job is a prompt on a schedule,
not an issue.

### A cron expression on a system cron daemon

Shell out to the OS `cron`. Rejected: it breaks BEAM-native supervision and durability, needs host
cron access (absent in containers and on a `$5 VPS`), and cannot inject skills or deliver through the
gateway.

### One-shot timers without persistence

Keep jobs in memory only. Rejected: a restart would silently drop every recurring job. Persisting to
`Core.Stores.Dets` and replaying on boot is the minimum for a scheduler worth trusting.

## Validation

- **Existing behavior unchanged.** With no scheduler configured, no `cronjob` Action is exposed and
  Symphony's loop is untouched.
- **Schedule parsing test:** each of the four formats parses to the correct next-fire time; a
  timestamp job is one-shot, the others recur.
- **Persistence test:** create jobs, restart the scheduler, and confirm the jobs reload and re-arm
  from their next-fire times.
- **Fresh-agent test:** two fires of the same job share no conversation history; the job's attached
  skills are present in each fire.
- **Recursion-guard test:** a `cronjob` `create`/`run` inside a cron run returns an error and creates
  nothing.

## References

- `~/Desktop/hermes-extraction-report.md` (item H2.2; the Hermes cronjob tool + cron internals)
- ADR-0021: Self-improving agents (the `Skills.Store` a fire injects from)
- ADR-0023: Unified messaging gateway (the delivery path for job targets)
- `packages/raxol_symphony/lib/raxol/symphony/orchestrator.ex` (the existing fixed-cadence poll the
  general scheduler generalizes away from)
- `packages/raxol_core/lib/raxol/core/stores/dets.ex` (the persisted job store)
- `packages/raxol_agent/lib/raxol/agent/scheduler/fire.ex` (the shipped fire path: skills injected
  from the `Skills.Store`, then `Raxol.Agent.Stream.react/2`)
