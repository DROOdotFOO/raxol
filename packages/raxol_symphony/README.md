# Raxol Symphony

A Raxol port of [OpenAI Symphony](https://github.com/openai/symphony): an
orchestrator that turns tracker work into autonomous coding-agent runs. Each
issue gets an isolated workspace, runs an agent until the work reaches a
workflow-defined handoff state, and surfaces evidence (CI/PR/walkthrough) so
engineers manage outcomes rather than prompts.

Implements [`SPEC.md`](https://github.com/openai/symphony/blob/main/SPEC.md).

## Status

Release-packaged as 0.2.0; 738 tests pass. Two runner backends ship:
`raxol_agent` (default, wraps `Raxol.Agent.Stream`) and `codex app-server`
(Port-based JSON-RPC for parity with upstream Symphony Elixir). Three
workflow modes: `default` (inline), `graph` (per-node checkpointed
pipeline), and `graph_parallel` (batches eligible issues into one fan-out
run per tick). Six surfaces (terminal dashboard, LiveView, MCP, Telegram,
Watch, JSON API). Evidence collection (CI status, PR comments, complexity,
asciinema replays) ships per run. Pre-alpha until a live workflow run
against a real Linear / GitHub repo is captured (see
[`RUNBOOK.md`](RUNBOOK.md)) and 0.2.0 is published to Hex.

## Trust posture

Designed for trusted developer-machine deployments. The default `raxol_agent`
runner uses `CommandHook` + `PermissionHook` to deny shell operations outside
the per-issue workspace. See `SPEC.md` s15 for hardening guidance.
