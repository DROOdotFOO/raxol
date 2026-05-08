# Raxol Symphony

A Raxol port of [OpenAI Symphony](https://github.com/openai/symphony): an
orchestrator that turns tracker work into autonomous coding-agent runs. Each
issue gets an isolated workspace, runs an agent until the work reaches a
workflow-defined handoff state, and surfaces evidence (CI/PR/walkthrough) so
engineers manage outcomes rather than prompts.

Implements [`SPEC.md`](https://github.com/openai/symphony/blob/main/SPEC.md).

## Status

Phases 0-14 complete; 399 tests pass. Two runner backends -- `raxol_agent`
(default, wraps `Raxol.Agent.Stream`) and `codex app-server` (Port-based
JSON-RPC for parity with upstream Symphony Elixir) -- and six surfaces
(terminal dashboard, LiveView, MCP, Telegram, Watch, JSON API). Evidence
collection (CI status, PR comments, complexity, asciinema replays) ships
per run. Pre-alpha until live workflow validation against a real Linear /
GitHub repo and Hex name reservation.

## Trust posture

Designed for trusted developer-machine deployments. The default `raxol_agent`
runner uses `CommandHook` + `PermissionHook` to deny shell operations outside
the per-issue workspace. See `SPEC.md` s15 for hardening guidance.
