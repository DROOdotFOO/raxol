# ADR-0042: Lean on OMP; Raxol is what agents plug into

## Status

Proposed, 2026-10-23. Revised the same day after a review pass that checked
every claim against the code and against OMP 18.12.6 itself (its bundled
source and a throwaway plugin driven through `omp --mode rpc`), and again
after an adversarial pass and the owner's decisions on tool churn, plugin
location, teams, payments and where agents live.

Supersedes [ADR-0034](0034-foreign-coding-agent-seams.md) (foreign coding-agent
seams) once the harness is deleted. The same deletion supersedes ADRs 0022,
0024, 0026, 0027 and 0028 and narrows 0021, 0032, 0035, 0036 and 0037 (table
under Consequences); each is re-marked in the PR that removes its code, not
before. Amends [ADR-0012](0012-mcp-as-rendering-target.md): derived tool names
become session-scoped and a session's tool set becomes sticky (Decision 2).

## Context

Raxol grew a full coding-agent harness: the coding TUI (`raxol code`,
`mix raxol.code`, 7.4k lines in `Raxol.Agent.Code.*`), a one-shot mode
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
- **Agents that survive crashes.** Supervised, crash-isolated BEAM processes
  (`Raxol.Agent.Session`, `Team`, `Comm`), with journals they resume from,
  schedules (`Raxol.Agent.Scheduler`), sandboxes and fail-closed spend limits
  (`Raxol.Agent.SpendGate`, `raxol_payments`).
- **Every surface.** Terminal, LiveView, SSH, MCP, Telegram, watch.

The derived tools never reach OMP usefully today. OMP sees the 11 static
tools (six in `Raxol.Headless.McpTools`, five `adaptive_*`), so an OMP agent
drives a Raxol app the way it would scrape any TUI. Derived tool names also
carry no session prefix (`"#{widget_id}.#{action_name}"`,
`packages/raxol_mcp/lib/raxol/mcp/tree_walker.ex:228`) in one ETS `:set`
keyed by name. `ToolSynchronizer.do_sync` registers only names new to its own
session and unregisters by bare name (`tool_synchronizer.ex:294,298`), so a
second session with the same widget id takes over the first one's tool,
the first never registers it again, and stopping either removes it for both.
The per-session `discover_tools` collides the same way
(`tool_synchronizer.ex:114-116`, `focus_lens.ex:83`).

Derived write tools also do not reach application state today. A widget's
tool handler returns a raw message such as `{:sort, id, column, direction}`
(`lib/raxol/ui/components/table.ex:918-924`). The tool callback casts it to
the dispatcher as an event, and the dispatcher's generic path treats it as an
`Event` struct (`lib/raxol/core/runtime/events/dispatcher.ex:917-928`). No
playground demo has an `update/2` clause for these messages either. The OMP
session that drove `TableDemo` worked only through `raxol_send_key`. Making
write tools change state end to end is therefore the first step of
Decision 2, not an assumption under it.

## Decision

### 1. The story

Raxol stops being a coding harness. Its sentence becomes: **write one app;
people and AI agents both use it, on every surface, and the agents that run
behind it don't fall over.** OMP is the harness people talk to; Raxol is
what it plugs into:

- Raxol apps are OMP tools (MCP, widget-derived).
- Raxol agents are crash-isolated, journaled workers an OMP session starts,
  asks, checks and stops (MCP), and that can spend money inside
  Raxol-enforced limits (Decision 7).
- Raxol surfaces can front an OMP session (OMP's RPC mode) on Telegram, the
  web, SSH or a watch.

`AGENTS.md`'s Hermes section and every "Hermes parity" claim are retired. A
coding harness joins the "Do NOT build" list.

### 2. Apps into OMP first

The first build exposes each headless session's derived tools to OMP.

- **Session-scoped names.** Derived tools become
  `<session>.<widget>.<action>`, and `discover_tools` becomes
  `<session>.discover_tools`, which fixes the cross-session takeover on its
  own. Under the plugin, OMP names them
  `mcp__raxol_raxol_<session>_<widget>_<action>` (plugin name, then server
  name; observed), so 47 characters remain for session, widget and action.
  Past 64 characters OMP keeps a readable prefix and appends a hash, so long
  names still work; short session ids keep them readable. Ids from MCP input
  are validated before any atom is created.
- **Dynamic publication.** The server advertises `tools.listChanged` and
  sends `notifications/tools/list_changed` on every change, and OMP re-lists
  on it (observed). OMP lists MCP tools as text at the end of its system
  prompt, so every change rewrites that text mid-conversation. To keep that
  rare, a session's tool set is sticky: a tool stays registered until its
  session stops. Each call resolves its widget's live state at call time
  (today a callback captures the widget as it was when the tool was derived,
  `tree_walker.ex:224-236`, which a sticky set would freeze). A call to a
  widget that is absent, disabled or of another type returns an error naming
  it. Churn is then limited to session start, stop and a widget's first
  appearance. Derived descriptions are static per widget type and action, so
  app text never reaches OMP's system prompt. Users can shed tools: a
  per-session cap evicts the least recently used, `raxol_compact` drops tools
  for widgets no longer in view, `raxol_stop` drops a session's whole set,
  and `raxol_list` shows each session's count. Whether the remaining churn
  costs provider cache hits is measured by the benchmark below.
- **Authorization stays in Raxol.** OMP treats every MCP tool as a `write`
  tool, ignores annotations, and auto-approves in its default mode, so the
  Raxol authorizer is the only gate, at the resource. `TreeWalker` passes a
  provider's annotations through (it drops them today), and state-changing
  widget actions are marked sensitive. Over stdio the peer is the process
  that spawned the server, so `raxol mcp` installs an explicit allow
  authorizer. A network deployment must supply a function authorizer, since
  derived names are dynamic and an exact-name allowlist cannot list them.
- **The static `raxol_*` tools stay**, for starting, stopping and
  screenshots. Keystrokes remain a fallback, not the path.
- **Distribution is an OMP plugin in this repository.**
  - The catalog is `.omp-plugin/marketplace.json` at the repository root.
    The plugin lives in `integrations/omp/raxol/`: `plugin.json`, `mcp.json`,
    a `raxol-operator` skill and a `raxol-operator` subagent.
  - OMP confines a plugin server's command to a bare executable name or a
    plugin-relative path. It also confines `cwd` to the plugin's own root or
    data directory, so a plugin cannot run `mix mcp.server` in a user's
    project. The plugin therefore runs `raxol mcp`, a new `@raxol/cli`
    subcommand that needs no Elixir toolchain.
  - `raxol mcp` sets the MCP startup mode before the release boots, sends
    logs to stderr, and gets a smoke test in the CLI release workflow.
  - App authors expose their own modules with a project `.omp/mcp.json`
    pointing at `mix mcp.server` with their project as `cwd`.
- **The first headline benchmark comes from this step.** A deterministic
  tier runs on every PR: reference tasks solved in-process through derived
  tools and through keys plus screenshots, recording calls and bytes. A
  weekly tier, capped at $10 a week, runs the same tasks with OMP as the
  agent and records completion, tool calls and tokens, including cache reads
  and writes.

### 3. Delete the coding harness, after a dependency check

The dependency check found that kept code still leans on the harness in
places. Policy helpers live on `Actions.Code`. `Stream` (the scheduler's
path) calls the memory manager, and the `Command` struct uses the coding
event codec. The Symphony runner and `raxol acp` are built on coding modules.
So the deletion is still one clean-cutover PR, but three behaviour-preserving
PRs go first:

1. Decouple the kept code from the harness without changing behaviour: move
   the policy helpers and the codec, and take the OpenRouter branch out of
   the kept auth flow. The memory, self-improvement and user-model hooks are
   public `use Raxol.Agent` callbacks, so they go in the cutover itself.
2. Replace Symphony's coding runner with an `omp` runner (`omp -p --mode
   json`) beside the existing Codex runner.
3. Rebuild `raxol acp` on Raxol agents (Decision 5).

The cutover PR deletes coding-only code:

- `Raxol.Agent.Code.*`.
- `Harness.{ClaudeCode, Cursor, GrokBuild, ToolExecutor, McpTools,
  McpToolConfig, StreamJson, SessionInbox, ToolClassifier}`.
- `Backend.{Native, ClaudeCode, Cursor, GrokBuild}` and `NativeHarness`.
- Shell, LSP context, compaction, memory and user model, self-improvement,
  curation and trajectories, probes, setup, and `Raxol.Agent.P`.
- The coding `Actions`: code, fs, shell, workspace, lsp, anchor, vfs, memory,
  session search, fetch, web search and task.
- The ACP coding turn runner and login. The permission bridge is re-targeted
  rather than deleted (Decision 5).
- Code the cutover leaves without callers: `Auxiliary`, `AcpStreamAdapter`,
  `Backend.Cli`, `SignalTrap` and `Fingerprint`. `LlmPrices` stays, because
  Decision 4 prices `omp_gateway` replies with it.
- The SSH code server and the `Harness.McpTools` registration in
  `Raxol.Application`.
- The CLI commands `agent`, `code`, `p`, `login` and `setup`, with their mix
  tasks and `bin/` scripts. Bare `raxol` prints help.

Measured, that is about 24k lines of `raxol_agent` library code, and 82 test
files reference it.

Kept, because they are the Raxol-agents runtime or have outside users:

| Kept | Why |
|---|---|
| `Raxol.Agent.Session`, `Team`, `Comm`, `Supervisor`, `Journal`, `SpendGate`, `Sandbox`, `ToolPolicy`, `Policy`, `ThreadLog`, `Cache`, `Stream`, `Turn`, `Command` | the agent runtime; `raxol_payments` compiles against `Action`, `CommandHook` and `Command` |
| `Raxol.Agent.Scheduler` (with `Fire`, `Delivery`), `Skills`, `Skills.Store`, `Actions.{Skills, Cronjob, Web3, FX}`, `McpBundle` | `raxol_console` (ADR-0031) wires them |
| `Raxol.Agent.Harness.SessionLane` | implements the root `Raxol.Harness.SessionLane` behaviour from the runtime alone |
| `Raxol.Agent.Backend.Mock` | a runtime fallback in `ExecutorConfig` and `Resolver`, and a test backend for other packages |
| `Raxol.Agent.Auth.{Flow, Robinhood, Pkce, Loopback, Credential}`, `BenchmarkProfile` | `raxol_broker`'s Robinhood login uses the auth flow; `BenchmarkProfile` is used by kept pricing and budget code |
| `Raxol.Harness.*` and `Raxol.UI.Harness.*` (root) | the agent-session UI kit; re-pointed at OMP sessions in Decision 6 |
| `raxol_agent_client_protocol` | Decision 5 |

The cutover also resolves its outside edges in the same PR:

- `raxol_cli`'s `doctor`.
- The `raxol_payments` tools-docs task and its `Code.CostLedger` test.
- The CI entrypoint and ACP loopback jobs.
- The CLI release workflow's `raxol p` smoke, replaced by the `raxol mcp`
  smoke.
- The quality baseline.
- The docs, the web landing page and `llms.txt` sources that describe the
  coding agent.

### 4. Model access: one direct family plus the OMP gateway

The backend catalog's model entries shrink to `anthropic`, `ollama` and a new
`omp_gateway`. `mock` stays as the offline and test backend, and the reserved
`codex` entry stays for Symphony's runner.

`omp_gateway` runs `omp auth-gateway stdio`:

- The first line is `{"ready":true,"version":...}`. Requests are JSON lines
  `{id, path, body}`, answered by id in completion order.
- It reaches every provider OMP is logged in to, including role models such
  as `@smol`.
- It shares one Anthropic Messages codec with the direct backend.
- It declares `:completion` and `:tool_use`, the latter confirmed by a live
  call before release. It does not declare `:streaming`, because the gateway
  returns a streamed reply as one string after the stream ends.
- It never claims to handle tools internally, which would bypass
  `SpendGate`.
- It is a new `:gateway` catalog kind, used only when selected explicitly,
  never auto-detected. Its binary must belong to the user and must not be
  group- or world-writable. Replies are priced through `LlmPrices` from the
  model that actually answered.

Headless servers keep working without Bun through the direct Anthropic and
Ollama backends. The HTTP backend is split rather than deleted: its
Anthropic and Ollama clauses stay, and an unknown provider becomes an error
instead of falling through to OpenAI. Lumo, the OpenAI-compatible family and
Kimi are deleted; the native CLI drivers go with the harness.

### 5. ACP stays, aimed at Raxol agents

`raxol acp --agent <app>[:<id>]` keeps serving ACP, but a session talks to a
Raxol agent instead of starting a coding turn:

- Agents are session-scoped for now. The agent runs inside the `raxol acp`
  process for the editor session; its journal persists, and starting the
  same id again resumes from it. A long-lived host that several processes
  attach to is later work: a 0600 unix socket with a peer-uid check, never
  Erlang distribution, which `raxol_payments` forbids on signing nodes.
- The package's arity-2 `:turn_runner` seam takes a runner that calls the
  agent (`Comm.call/3`, with an explicit timeout; the agent answers with
  `Comm.reply/3`) and sends its reply as message chunks.
- `session/cancel` tells the agent to abort the turn in flight. The agent
  keeps running until the editor session ends or it is stopped with
  `Session.Supervisor.stop_session/1`.
- The permission bridge stays, re-targeted: a prompt's sensitive actions
  still ask the editor per call, because auto-approval has no place on an
  agent that holds a wallet.
- `ParentWatch` and the `serve` scaffolding stay. `Budget` stays only if the
  agent's reply carries usage for it to record; otherwise it goes with the
  coding turn runner. The coding toolset, prompt and executor detection go.
- Without `--agent`, `initialize` still succeeds, so registry checks that run
  `raxol acp` bare keep working.

This lands before the cutover, because today's server is built from modules
the cutover deletes. Editors that want a coding agent use `omp acp`.

### 6. Raxol surfaces front OMP, later

An Elixir client for OMP's RPC mode (`omp --mode rpc`) lets the root
`Raxol.Harness` UI kit render an OMP session on any Raxol surface:

- The protocol is JSON lines with id correlation, `negotiate_protocol` v2
  chunking for frames over 1 MiB, and waiting for `session_settled` before
  teardown.
- The RPC ready frame carries no version, so the client checks
  `omp --version` against the pin.
- It plugs in as a `raxol_agent` implementation of the root
  `Raxol.Harness.SessionLane` behaviour, which gains a prompt callback.
- OMP runs with `--approval-mode write`, and its approval requests go to the
  surface's authenticated user. A surface without one (for example a
  Telegram bot with no chat allowlist) refuses to start an OMP session,
  because OMP's default mode would hand that chat a shell.

This replaces the deleted coding TUI with "OMP on Telegram, LiveView, SSH and
a watch".

### 7. Raxol agents into OMP

The `raxol mcp` server gains agent tools: spawn, list, ask, status and stop,
team spawn, list, broadcast and stop, and a read-only journal resource per
agent.

- Agents run inside the `raxol mcp` process and end with the OMP session.
  Their journals persist, and spawning the same id again resumes from them.
  A second process cannot take an id whose journal another process holds.
- Only apps on a configured allowlist can be spawned, and the tools act only
  on agents this process spawned.
- `Team` gains list, member and stop functions and stops creating atoms from
  team ids.
- Spending tools ship here, under the payments rules in Consequences.

## Consequences

- About 24k lines of `raxol_agent` library code and the tests that cover it
  go, with the CLI's agent commands and their docs (measured over the
  delete set; the earlier 15-20k estimate was low).
- Raxol depends on a third-party harness for the coding experience. MCP is
  the stable seam. OMP releases often, so CI and the docs pin a tested
  version (18.12.6 at review) through the install script's `--ref` flag:
  `curl -fsSL https://omp.sh/install | sh -s -- --binary --ref v18.12.6`.
  The gateway and RPC clients check the version at startup.
- Agents in OMP use Raxol apps through semantic tools, which is the claim the
  benchmark measures.
- Payments stay in the Raxol-agents story. The npm `raxol` binary bundles
  `raxol_payments`, so plugin users get spending tools once an operator
  writes a policy: caps, currency and approved recipients. Payment tools go
  through the payments gate (`Raxol.Payments.Actions.SpendGate.authorize/3`
  and the ledger), not the LLM-cost `Raxol.Agent.SpendGate`. Without a policy
  and ledger no payment tool registers; a recipient outside the approved list
  or a currency other than the policy's is refused; caps never come from tool
  arguments. OMP cannot ask a human through MCP (it answers only `ping` and
  `roots/list`), so an amount that needs confirmation is refused rather than
  approved. OMP's approval mode is never the control.
- Derived tool sets still change when sessions start and stop. The weekly
  benchmark records cache reads and writes so the cost is measured, not
  guessed.
- ADRs re-marked by the deletion:

| ADR | Becomes | Because |
|---|---|---|
| 0021 | Narrowed | `Skills.Store` stays; `SelfImprove` and `Curator` go |
| 0022 | Superseded | memory stack, session search and user model go |
| 0024 | Superseded | the native execution backends go |
| 0026 | Superseded | `execute_code` was never built and the coding harness it served is gone |
| 0027 | Superseded | `Actions.Task` goes; OMP owns subagent fan-out |
| 0028 | Superseded | `Auxiliary`'s only callers (`SelfImprove`, `UserModel`) go, leaving it dead |
| 0032 | Narrowed | `Actions.Fs` goes; its sandboxed-spawn design stays as the open follow-up for unattended runners such as the Symphony `omp` runner |
| 0034 | Superseded | the foreign coding-agent seams go; its catalog derivation policy and Symphony-on-OMP notes carry into this ADR's follow-up PRs |
| 0035 | Narrowed | `LlmPrices` prices `omp_gateway` replies; its DeepSeek scoped rows go with the backend |
| 0036 | Narrowed | the tier-1 events are emitted only from `Code.App` |
| 0037 | Narrowed | `.mcp.json` admission lived in `Code.McpConfig` |

ADRs that keep their decision but cite deleted code get an amendment note in
the PR that breaks them: 0018, 0020, 0031, 0033, 0038 and 0040. 0023 and 0025
get a status note retiring their Hermes-parity framing.

## References

- OMP docs (`omp://` in an OMP session): `mcp-config.md`,
  `mcp-runtime-lifecycle.md`, `mcp-server-tool-authoring.md`,
  `marketplace.md`, `approval-mode.md`, `rpc.md`, `auth-broker-gateway.md`,
  `task-agent-discovery.md`.
- OMP 18.12.6 source, `packages/coding-agent/src/discovery/agent-plugin-format.ts`
  (plugin `mcp.json` rules), and the Agent Plugins 1.0.0 schemas
  (`https://agent-plugins.org/schemas/1.0.0/plugin.schema.json`,
  `.../mcp.schema.json`).
- [ADR-0012](0012-mcp-as-rendering-target.md), MCP as a rendering target.
- [ADR-0031](0031-console-runtime-integration.md), the Console runtime that
  keeps the scheduler and skills store.
- [ADR-0041](0041-agent-client-protocol-package.md), the ACP package.
