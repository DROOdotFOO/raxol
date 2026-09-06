# Changelog

All notable changes to `raxol_symphony` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - unreleased

First release of the Symphony orchestrator. Pre-alpha until a live workflow
run against a real GitHub or Linear repo is captured (see `RUNBOOK.md`); the
code surface below is stable and test-covered.

### Added

- **Orchestrator** (`Raxol.Symphony.Orchestrator`): a `BaseManager` GenServer
  that polls a tracker, claims eligible issues, isolates each in a per-issue
  workspace, and runs a coding agent to a workflow-defined terminal state.
  Bounded concurrency, continuation + exponential-backoff retries, stall
  detection, and per-tick tracker reconciliation.
- **Trackers**: Memory (test), Linear (GraphQL), and GitHub (REST + state
  labels), behind a common `Tracker` behaviour.
- **Runners**: `Runners.RaxolAgent` (default, wraps `Raxol.Agent.Stream`),
  `Runners.RaxolAgentSession` (full `Raxol.Agent.Session` lifecycle), and
  `Runners.Codex` (Port-spawned `codex app-server`, JSON-RPC 2.0 over stdio).
- **`:graph_parallel` workflow mode**: batches up to `workflow_parallelism`
  eligible issues into one fan-out graph run per tick via
  `Workflow.GraphAdapter.from_workflow_parallel/1`, with isolated per-slot
  workspaces. Batch issues are counted against `max_concurrent_agents`, and
  each slot's outcome fans back to the per-issue continuation/failure-retry
  paths on batch exit. A branch that pauses is parked as resumable, the same
  way a sequential run is; compensating the sibling branches that already
  completed is still open (#517).
- **`:graph` workflow mode**: routes each dispatched worker through the
  canonical `GraphAdapter` pipeline (per-node telemetry, resumable
  checkpoints, and a runner pause/resume loop).
- **Six surfaces** over `Phoenix.PubSub`: terminal dashboard, LiveView, MCP
  (5 tools + a `symphony://runs` resource), Telegram, Watch, and a JSON API.
- **Evidence framework** (`Evidence.collect/3` + `Evidence.Capture`): GitHub
  CI status, PR comments, complexity (cloc / SLOC fallback), and per-run
  asciicast recordings.
- **WorkflowStore**: hot-reloads `WORKFLOW.md` via `file_system`, serving the
  last-known-good config on parse failure.
- **Worker host pool** (`Worker.{HostPool, HostSpec}` + `Symphony.SSH`):
  optional `worker.ssh_hosts` gate dispatch on a free host and give a remote
  worker a workspace on its own host. `snapshot/1` reports
  `%{total, free, busy}` when hosts are configured and `nil` when they are not.
- **Durable paused runs** (`Orchestrator.PausedSaver`): a paused run is
  persisted and rehydrated at boot, and a run that would pause without a
  durable saver is refused rather than silently losing the pause. Resume goes
  back to the agent that asked (`Resumer`, `OperatorCallback`,
  `PauseReason`, `ResumeOn`).
- **Codex runner auth** as a first-class concern: config, environment, and a
  preflight check, with subscription backends preferred over API credits.
- **Review stage** (`Review` + `Review.Contract` + `Runners.Review`): an
  optional reviewer pass with `select_reviewer/3` cross-vendor escalation,
  validated at preflight so a configuration dispatch could never run is
  rejected before the first tick instead of parking every issue.
- **Sandbox policies** (`Sandboxes.{BudgetCap, TimeOfDayWindow, TurnRateLimit}`)
  bounding spend, clock, and turn rate per run.
- **Workspace confinement**: `workspace_path` is required of every runner, and
  the agent's own tools are pinned to that path, so a run cannot reach the
  repository the orchestrator was started in. `PathSafety` and `PortReaper`
  back the filesystem and process boundaries.
- **Money-path telemetry** (ADR-0036) on dispatch and settlement.

### Fixed

- Evidence capture is unlinked from the run it records, so a capture failure
  cannot take the run down. Each dispatch writes its own asciicast fragment
  rather than truncating the previous one, and cast truncation cuts on a
  codepoint boundary.
- Retry handling: bounded refresh, growing backoff across tracker outages,
  concurrency capped on retry and resume dispatch, a claimed retry re-armed
  when no host is free, and ticks dropped from superseded orchestrator timers.
- Tracker handling: state lists validated at preflight, non-map `WORKFLOW.md`
  sections rejected at load, an absent GitHub issue distinguished from an
  unreachable tracker, and a running entry's state moved with its issue.
- A turn whose stream never completes now fails the turn instead of hanging
  the run. Stopping a port kills its child process group.

### Security

- Policy telemetry no longer carries the wrapped operation's argument
  (ADR-0036), which for a prompt-keyed cache policy meant the prompt itself.
