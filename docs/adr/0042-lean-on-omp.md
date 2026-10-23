# ADR-0042: Lean on OMP; Raxol is what agents plug into

## Status

Proposed, 2026-10-23.

Supersedes [ADR-0034](0034-foreign-coding-agent-seams.md) (foreign coding-agent
seams) once the harness is deleted. Narrows ADRs 0021, 0022, 0024, 0026, 0027,
0028 and 0032 to whatever survives the dependency check in Decision 3; each of
those is re-marked when its code is removed, not before.

## Context

Raxol grew a full coding-agent harness: the coding TUI (`raxol code`,
`mix raxol.code`, about 7.4k lines in `Raxol.Agent.Code.*`), a one-shot mode
(`raxol p`), an ACP agent server for editors, foreign-CLI drivers (Claude
Code, Grok Build, Cursor), shell, LSP, compaction, memory, self-improving
skills and a dozen model backends, most of it built for parity with Hermes
Agent. That market is crowded and led by harnesses with far more tuning
behind them. OMP (`omp`, <https://omp.sh>) ships 60+ providers, 32 built-in
tools, a native core and a plugin system, and it already speaks MCP well
enough to drive Raxol today: an OMP session started `TableDemo` through
`mix mcp.server`, pressed `j` with `raxol_send_key` and read the screen back.

What no coding harness has is what Raxol already is:

- **Apps an agent can operate.** A Raxol app derives MCP tools from its widget
  tree (`Raxol.MCP.TreeWalker`, `Raxol.MCP.ToolSynchronizer`): `table.sort`,
  `search.type_into`, `dialog.dismiss`, instead of keystrokes and screen text.
- **Agents that outlive a chat.** Supervised, crash-isolated BEAM processes
  (`Raxol.Agent.Session`, `Team`, `Comm`), with journals, schedules
  (`Raxol.Agent.Scheduler`), sandboxes and fail-closed spend limits
  (`Raxol.Agent.SpendGate`, `raxol_payments`).
- **Every surface.** Terminal, LiveView, SSH, MCP, Telegram, watch.

The derived tools never reach OMP today: OMP sees only the 11 static tools,
so an OMP agent drives a Raxol app the way it would scrape any TUI. And
derived tool names carry no session prefix (`"#{widget_id}.#{action}"`, one
global ETS registry keyed by name), so two headless sessions with the same
widget id overwrite each other's tools.

## Decision

### 1. The story

Raxol stops being a coding harness. Its sentence becomes: **write one app;
people and AI agents both use it, on every surface, and the agents that run
behind it don't fall over.** OMP is the harness people talk to; Raxol is
what it plugs into:

- Raxol apps are OMP tools (MCP, widget-derived).
- Raxol agents are durable workers an OMP session starts, asks, checks and
  stops (MCP), and that can spend money inside Raxol-enforced limits.
- Raxol surfaces can front an OMP session (OMP's RPC mode) on Telegram, the
  web, SSH or a watch.

`AGENTS.md`'s Hermes section and every "Hermes parity" claim are retired. A
coding harness joins the "Do NOT build" list.

### 2. Apps into OMP first

The first build exposes each headless session's derived tools to OMP:

- Derived tool names become session-scoped (`<session>.<widget>.<action>`),
  which fixes the cross-session overwrite on its own. OMP sanitizes them to
  `mcp__raxol_<session>_<widget>_<action>` and hashes names past 64
  characters, so session ids stay short.
- Tools are published dynamically: the server already advertises
  `tools.listChanged` and sends `notifications/tools/list_changed` on every
  change, and OMP re-lists on that notification (`refreshServerTools`).
- The static `raxol_*` session tools stay, for starting, stopping and
  screenshots. Keystrokes remain a fallback, not the path.
- Distribution is an OMP plugin in this repository: `plugin.json`, an
  `mcp.json` whose stdio command is `raxol mcp` (a new `@raxol/cli`
  subcommand, so no Elixir toolchain is needed), an operator skill, and a
  `raxol-operator` subagent. App authors point a project `.omp/mcp.json` at
  `mix mcp.server` to expose their own modules.
- The first headline benchmark comes from this step: the same tasks, done by
  OMP through derived tools and through keystrokes plus screenshots, with
  completion, tool calls and tokens for each.

### 3. Delete the coding harness, after a dependency check

One clean-cutover PR, after step 2 ships `raxol mcp`. Coding-only code goes:
`Raxol.Agent.Code.*`, `Harness.{ClaudeCode, Cursor, GrokBuild, ToolExecutor,
McpTools, StreamJson}`, `Backend.Native` and its drivers, shell, LSP context,
compaction, memory and user model, self-improvement and curation, probes,
`Raxol.Agent.P`, the coding `Actions` (filesystem, shell, code), the SSH code
server in `Raxol.Application`, and the CLI commands `agent`, `code`, `p`,
`login` and `setup` with their mix tasks.

Kept, because they are the Raxol-agents runtime or have outside users:

| Kept | Why |
|---|---|
| `Raxol.Agent.Session`, `Team`, `Comm`, `Supervisor`, `Journal`, `SpendGate`, `Sandbox`, `ToolPolicy`, `Policy`, `ThreadLog`, `Cache` | the agent runtime |
| `Raxol.Agent.Scheduler`, `Raxol.Agent.Skills.Store` | `raxol_console` (ADR-0031) wires both |
| `Raxol.Harness.*` and `Raxol.UI.Harness.*` (root) | the agent-session UI kit; re-pointed at OMP sessions in Decision 6 |
| `raxol_agent_client_protocol` | Decision 5 |

Blocking edges the PR resolves rather than breaks:

- `raxol_symphony`'s `raxol_agent` runner is a coding runner (`Actions.Code`,
  `Actions.Fs`, `Sandbox.Shell`). It is replaced by an `omp` runner
  (`omp -p` / `--mode json`) beside the existing Codex runner.
- `raxol_cli`'s `doctor` reads `Raxol.Agent.Code.Inspection` and the ACP
  agent; it is narrowed to what remains.
- `raxol_payments`' `code_llm_ledger_test.exs` exercises
  `Raxol.Agent.Code.CostLedger`; the ledger moves or the test goes with it.
- `web/`'s playground capability probe for the ACP agent follows Decision 5.

### 4. Model access: one direct family plus the OMP gateway

The backend catalog shrinks to `anthropic`, `ollama` and a new `omp_gateway`.
`omp_gateway` runs `omp auth-gateway stdio` (JSON lines `{id, path, body}`,
`POST /v1/messages`) and so reaches every provider OMP is logged in to,
including role models such as `@smol`. The gateway returns a streamed reply
only after it ends, so `omp_gateway` declares `[:completion]`, not
`:streaming`. Headless servers keep working without Bun through the direct
Anthropic and Ollama backends. Lumo, the OpenAI-compatible family, Kimi and
the native CLI drivers are deleted.

### 5. ACP stays, aimed at Raxol agents

`raxol acp` keeps serving ACP, but a session attaches to a named, long-lived
Raxol agent instead of starting a coding turn. The package's arity-2
`:turn_runner` seam takes a runner that calls the agent (`Comm.call/3`) and
streams its reply. `Budget`, `ParentWatch` and the `serve` scaffolding stay;
the coding permission bridge and executor detection go. `Session` gains an
explicit stop for `session/cancel`. Editors that want a coding agent use
`omp acp`.

### 6. Raxol surfaces front OMP, later

An Elixir client for OMP's RPC mode (`omp --mode rpc`: JSON lines, id
correlation, `negotiate_protocol` v2 chunking, `session_settled` before
teardown) lets the root `Raxol.Harness` UI kit render an OMP session on any
Raxol surface. This replaces the deleted coding TUI with "OMP on Telegram,
LiveView, SSH and a watch".

## Consequences

- Roughly 15-20k lines of `raxol_agent` and their tests go [estimate, to be
  replaced by the deletion PR's actual count], with the CLI's agent commands
  and their docs.
- Raxol depends on a third-party harness for the coding experience. MCP is
  the stable seam; the RPC and auth-gateway protocols are versioned and get
  pinned to a tested OMP version.
- Agents in OMP use Raxol apps through semantic tools, which is the claim the
  benchmark measures.
- Payments stay in the Raxol-agents story: spend limits are enforced in
  `SpendGate` and `raxol_payments`, at the resource; OMP's approval prompt is
  a convenience on top, never the control.
- Derived tool sets change while an OMP conversation runs (a session starts,
  a modal opens). Whether that costs OMP prompt-cache hits is unmeasured.

## References

- OMP docs (`omp://` in an OMP session): `mcp-config.md`,
  `mcp-runtime-lifecycle.md`, `mcp-server-tool-authoring.md`,
  `marketplace.md`, `rpc.md`, `auth-broker-gateway.md`,
  `task-agent-discovery.md`.
- [ADR-0012](0012-mcp-as-rendering-target.md), MCP as a rendering target.
- [ADR-0031](0031-console-runtime-integration.md), the Console runtime that
  keeps the scheduler and skills store.
- [ADR-0041](0041-agent-client-protocol-package.md), the ACP package.
