# Symphony

`raxol_symphony` orchestrates coding agents against a ticket tracker. It's an Elixir/OTP port of OpenAI's [Symphony](https://github.com/openai/symphony). The orchestrator polls a tracker, claims eligible issues, isolates each one in a per-issue workspace, and runs a coding agent until the workflow hits a terminal state.

Status: pre-alpha. Not yet on Hex; use the path dep at `packages/raxol_symphony/`.

## Quick Start

```bash
mix raxol.symphony --workflow ./WORKFLOW.md
```

`WORKFLOW.md` defines tracker source, eligibility rules, retry policy, and per-issue runner config. It's hot-reloaded via `file_system`, so editing it doesn't restart the orchestrator. Last-known-good is served if a save leaves the file in an invalid state.

## Architecture

```
Tracker (Memory | Linear | GitHub Issues)
    |
    v
Orchestrator (BaseManager GenServer)
    |-- polls tracker, claims eligible issues
    |-- per-issue workspace under config.workspace.root
    |
    v
Runner (RaxolAgent | Codex)          PubSub
    |                                   |
    v                                   v
Coding agent run                    Six surfaces
                                    (terminal, LiveView,
                                     MCP, Telegram, Watch, JSON API)
```

## Runners

| Runner       | What it wraps                | Notes                                     |
| ------------ | ---------------------------- | ----------------------------------------- |
| `RaxolAgent` | `Raxol.Agent.Stream`         | Default. Same stack as `raxol_agent`.     |
| `Codex`      | `codex app-server` via Port  | JSON-RPC 2.0 over stdio. Three-step handshake (`initialize` -> `initialized` -> `thread/start`), per-turn `turn/start` cycles. |

Pick a runner per workflow. Mix-and-match isn't supported in a single run.

### Codex authentication

The Codex runner spawns the externally-authenticated `codex` CLI and does not
drive its interactive/OAuth sign-in (that stays out-of-band via `codex login`).
It only *selects and verifies* the credential the CLI already holds, via an
optional `codex.auth` block:

```
codex:
  command: "codex app-server"
  auth:
    mode: inherit        # inherit (default) | api_key | codex_home
    api_key_env: OPENAI_API_KEY   # env var *name* to read the key from (api_key mode)
    codex_home: ~/.codex          # CODEX_HOME to inject (codex_home mode)
    require_login: false          # hard-fail preflight when unauthenticated
```

Config stores only references (an env var name, a path), never the secret; the
key value is read from the environment at spawn and injected into the child
process. `mode: inherit` (the default) injects nothing and preserves the
ambient-env behavior. `require_login: true` makes an unauthenticated spawn fail
preflight with `{:error, :codex_unauthenticated}` instead of stalling mid-turn.
Each spawn emits `[:raxol, :symphony, :codex, :auth]` telemetry
(`%{mode, authenticated?, source}` -- never the secret).

## Surfaces

Every surface subscribes to the same orchestrator snapshot via Phoenix.PubSub, so they stay consistent without per-surface state:

- **Terminal**: TEA dashboard listing active runs and their state.
- **LiveView**: `/symphony` mounts the same dashboard in the browser.
- **MCP**: 7 tools (`list_runs`, `get_run`, `resume_run`, etc) plus `symphony://runs` as an MCP resource.
- **Telegram**: per-issue session, inline keyboards, approval prompts.
- **Watch**: debounced push to APNS/FCM, tap-to-approve actions.
- **JSON API**: `GET /api/v1/state`, `GET /api/v1/runs/:issue_id`, `POST /api/v1/refresh`, `POST /api/v1/runs/:issue_id/stop`.

## Evidence Collection

`Raxol.Symphony.Evidence.collect/3` runs per dispatch. It pulls:

- GitHub CI status and PR comments via the GitHub API
- Code complexity via `cloc` (falls back to SLOC if `cloc` isn't installed)
- Asciinema `.cast` recording of the agent's terminal session

Set `recording.enabled: true` in the workflow to capture casts. The `Evidence.Capture` GenServer writes one `.cast` per run under `evidence.dir`.

## Retry Behaviour

Three retry classes, configured per workflow:

| Class        | Trigger                         | Backoff                              |
| ------------ | ------------------------------- | ------------------------------------ |
| Continuation | Agent yields, expects re-prompt | Fixed 1s                             |
| Failure      | Run exits with error            | Exponential, `10s * 2^n`, capped     |
| Stall        | No output for `read_timeout_ms` | Restart from snapshot, no backoff    |

`turn_timeout_ms` bounds each individual turn; exceeding it bumps the stall counter.

## Configuration

`WORKFLOW.md` is parsed into `Raxol.Symphony.Workflow` at load time. Sample shape:

```yaml
---
tracker:
  type: github
  owner: example
  repo: thing
  labels: [agent-eligible]

workspace:
  root: ./symphony-workspaces

runner:
  type: raxol_agent
  read_timeout_ms: 120000
  turn_timeout_ms: 300000

recording:
  enabled: true
  dir: ./evidence

retry:
  failure_cap_ms: 600000
---
```

## See Also

- [Agent Framework](AGENT_FRAMEWORK.md): the runtime each agent runs in
- [MCP](MCP.md): how the orchestrator's MCP surface is derived
