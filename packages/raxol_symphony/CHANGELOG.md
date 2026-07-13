# Changelog

All notable changes to `raxol_symphony` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-13

First release-packaged cut of the Symphony orchestrator. Pre-alpha until a
live workflow run against a real Linear/GitHub repo is captured (see
`RUNBOOK.md`); the code surface below is stable and test-covered.

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
  paths on batch exit. Runner pauses are not supported in this mode.
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
