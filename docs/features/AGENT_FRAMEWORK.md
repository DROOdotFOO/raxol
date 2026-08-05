# Agent Framework

An agent is a TEA module where input comes from LLMs and tools instead of a keyboard. Same `init/update/view` loop, same OTP supervision, same crash isolation. The "user" is an AI model issuing commands and processing results.

For agent payment capabilities (wallets, spending controls, cross-chain transfers), see [Agentic Commerce](AGENTIC_COMMERCE.md). For the interactive coding agent built on this framework, see [Coding Agent](CODING_AGENT.md). For the learning and recall layers an agent can opt into, see [Self-Improvement](SELF_IMPROVEMENT.md) and [Memory](MEMORY.md).

## Quick start

```elixir
defmodule MyAgent do
  use Raxol.Agent

  def init(_ctx), do: %{findings: []}

  def update({:agent_message, _from, {:analyze, file}}, model) do
    {model, [shell("wc -l #{file}")]}
  end

  def update({:command_result, {:shell_result, %{output: out}}}, model) do
    {%{model | findings: [out | model.findings]}, []}
  end
end

{:ok, _} = Raxol.Agent.Session.start_link(app_module: MyAgent, id: :my_agent)
Raxol.Agent.Session.send_message(:my_agent, {:analyze, "lib/raxol.ex"})
```

## How it works

```elixir
use Raxol.Agent
    |
    v
Agent.Session (GenServer)
    |-- wraps Lifecycle with environment: :agent
    |-- skips terminal driver and plugin manager
    |-- registers in Agent.Registry for discovery
    |
    v
TEA cycle: init/1 -> update/2 -> view/1 (optional)
    |
    v
Commands: async/1, shell/1, send_agent/2
```

`use Raxol.Agent` sets up the standard TEA callbacks (`init/1`, `update/2`, `view/1`, `subscribe/1`) with defaults, and injects three command helpers:

- `async(fun)`: async command with a sender callback
- `shell(command, opts \\ [])`: shell command via Port
- `send_agent(target_id, message)`: message another agent

All callbacks are overridable. `view/1` defaults to `nil`, which means no rendering. Useful for headless agents that only process messages.

## Agent session

`Raxol.Agent.Session` is the GenServer hosting a single agent. It wraps `Lifecycle` with `environment: :agent`, which skips the terminal driver and plugin manager.

```elixir
# Start an agent
{:ok, _pid} = Raxol.Agent.Session.start_link(
  id: :code_reviewer,
  app_module: CodeReviewAgent
)

# Send a message (async, arrives as {:agent_message, from, payload} in update/2)
:ok = Raxol.Agent.Session.send_message(:code_reviewer, {:review, "lib/app.ex"})

# Read the agent's current model
{:ok, model} = Raxol.Agent.Session.get_model(:code_reviewer)

# Read the agent's rendered view tree
{:ok, tree} = Raxol.Agent.Session.get_view_tree(:code_reviewer)
```

Agents auto-register in `Raxol.Agent.Registry` by their `:id`. If the agent is dead, lookups return `{:error, :not_found}`.

## Communication

`Raxol.Agent.Comm` has three messaging primitives:

```elixir
alias Raxol.Agent.Comm

# Fire and forget
:ok = Comm.send(:target_agent, {:task, data})
# Arrives in target's update/2 as {:agent_message, from_id, {:task, data}}

# Synchronous call with timeout
{:ok, reply} = Comm.call(:target_agent, {:query, params}, 5_000)
# Caller blocks until {:agent_reply, ref, reply}

# Broadcast to every agent in a team
:ok = Comm.broadcast_team(:my_team, {:status_update, status})
# Arrives in each teammate's update/2 as
# {:agent_message, from_id, {:team_broadcast, :my_team, {:status_update, status}}}
```

## Teams

`Raxol.Agent.Team` is an OTP Supervisor for agent groups:

```elixir
{:ok, _} = Raxol.Agent.Team.start_link(
  team_id: :review_team,
  coordinator: {ReviewCoordinator, [id: :coordinator]},
  workers: [
    {FileAnalyzer, [id: :analyzer_1]},
    {FileAnalyzer, [id: :analyzer_2]}
  ],
  strategy: :rest_for_one
)
```

Coordinator starts first. With `:rest_for_one`, a coordinator crash restarts all workers. Workers crash independently.

## Command types

Commands returned from `update/2` are processed by Lifecycle:

| Command    | Helper                        | Result in update/2                                                   |
| ---------- | ----------------------------- | -------------------------------------------------------------------- |
| Async      | `async(fn sender -> ... end)` | `{:command_result, {:async_result, value}}`                          |
| Shell      | `shell("ls -la")`             | `{:command_result, {:shell_result, %{output: ..., exit_status: ...}}}` |
| Send Agent | `send_agent(:target, msg)`    | Delivered to target as `{:agent_message, from, msg}`                 |

## Headless agents

When `view/1` returns `nil` (the default), no rendering happens. The agent is a pure message-processing loop, good for background workers, data pipelines, or agents that only talk to other agents.

## AI backend streaming

`Raxol.Agent.Backend.HTTP` does real SSE streaming to LLM providers:

```elixir
{:ok, stream} = Raxol.Agent.Backend.HTTP.stream(
  [%{role: "user", content: "Explain OTP"}],
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  provider: :anthropic,
  model: "claude-sonnet-4-20250514"
)

# Stream elements:
# {:chunk, "text delta"}
# {:done, %{content: full_text, usage: %{...}}}
# {:error, "message"}
```

Supports Anthropic, OpenAI, Ollama, Proton's Lumo, Kimi 2.5/moonshot, OpenRouter, and Meituan's LongCat.
Provider is auto-detected from `:base_url` or set via `:provider`.

Without an explicit `:provider`, detection matches the `:base_url`: `anthropic` picks Anthropic, `ollama` (or the default Ollama port) picks Ollama, `moonshot` picks Kimi, and anything else is treated as OpenAI-compatible. The `FREE_AI=true` / `AI_API_KEY` backend switch is a convention of the example agents under `examples/agents/`, not the `Backend.HTTP` layer.

The `:openrouter` harness (via `Backend.Selector`) targets OpenRouter, an OpenAI-compatible aggregator. It attaches app-attribution headers (HTTP-Referer, X-OpenRouter-Title, X-OpenRouter-Categories) so Raxol's usage appears on openrouter.ai/rankings. Pass the key via `ExecutorConfig` `auth: %{api_key: ...}`.

The `:longcat` harness targets Meituan's LongCat (`https://api.longcat.chat/openai`, model `LongCat-2.0`), also OpenAI-compatible. It rides the `:openai` request/SSE path, which already handles LongCat's non-standard frames (a full `message` chunk instead of `delta`, the `reasoning_content` channel, and the underscore-less `finishreason` key). Pass the key via `ExecutorConfig` `auth: %{api_key: ...}`.

## Turn driver

`Raxol.Agent.Backend.HTTP` streams one model call. `Raxol.Agent.Turn` drives a whole
self-improving turn: it assembles tool context from the agent module's callbacks, runs the
reasoning loop, records the turn to a conversation log, then fires the background side
effects.

```elixir
{:ok, items} =
  Raxol.Agent.Turn.run(MyAgent, "refactor lib/foo.ex",
    backend: MyBackend,
    log: log_server,
    conversation_id: cid,
    agent_id: "my-agent",
    user_id: "user-123",        # optional, with :user_model
    user_model: MyApp.UserModel,
    session_search: MyApp.SessionSearch
  )
```

- `build_context/2` builds the tool context, each key present only when configured: memory
  (from `memory_providers`/`memory_provider`), skills (`skills_provider`), user context, and
  session search.
- `run/3` runs `Stream.react/2` with that context and records the stream into a
  [Conversation Log](#conversation-item-log).
- `after_turn/4` fires [self-improvement](SELF_IMPROVEMENT.md), the user-model refresh, and
  session indexing.

The agent *module* declares which providers it wants through zero-arity callbacks; the
*caller* supplies the running server instances through opts. Turn is the canonical driver
other runtimes can adopt.

## Native multi-vendor harness

An agent can run its own reasoning loop, or hand the loop to a vendor CLI (Claude Code,
Cursor) and expose Raxol's tools to it over MCP. `Raxol.Agent.ExecutorConfig`
(`%{harness, model, auth, opts}`) plus `Raxol.Agent.Backend.Selector.select/1` map a harness
atom to a backend:

| Harness | Backend |
|---------|---------|
| `:anthropic`, `:openai`, `:kimi`, `:ollama`, `:lm_studio`, `:llm7`, `:longcat`, `:openrouter` | `Backend.HTTP` |
| `:lumo` | `Backend.Lumo` |
| `:claude_native` | `Backend.ClaudeCode` |
| `:cursor` | `Backend.Cursor` |
| `:mock` | `Backend.Mock` |

A native backend reports `handles_tools_internally?/0` as `true`, which tells the framework
not to drive the reasoning loop: the CLI runs its own loop and calls Raxol's tools through an
injected MCP server (`Raxol.Agent.Harness.McpToolConfig` writes the `--mcp-config`). The
`:codex` harness is reserved (it speaks a stateful app-server protocol served by
`Raxol.Symphony.Runners.Codex`, not an agent backend), so `select/1` returns
`{:error, {:harness_not_implemented, :codex}}` for it.

## Authorization (ALLOW/ASK/DENY)

`Raxol.Agent.Authorization` is a three-way policy engine, richer than the deny-only
`PermissionHook`. It is what [`mix raxol.code`](CODING_AGENT.md) gates every mutating tool on.

- `Engine` is a pure reducer over a list of policies. It folds with `reduce_while`: a DENY
  short-circuits, an ALLOW merges whitelisted label writes, an ASK escrows writes and
  accumulates a prompt. Final precedence is deny > ask > allow.
- `Policy` is a data struct (`phases`, `conditions`, `writable_labels`, `scope`). Scope is
  `:once`, `:session`, or `:root`; a remembered ASK auto-allows within its scope, so
  "approve once covers the tree" works.
- `Server` is a per-workflow GenServer holding the policies and pending ASKs; `Hook`
  composes the engine into the `CommandHook` chain at the `:tool_call` phase, resolving an
  ASK through a synchronous prompter.

## Conversation item-log

`Raxol.Agent.Conversation` is a durable, append-only record of what an agent did, separate
from its compacted working memory.

- `Item` is an immutable typed entry (message, tool_call, tool_result, reasoning, error, and
  more) with a stable id `"<conversation_id>:<seq>"` and a monotonic, store-assigned seq.
- `Store` is a behaviour with cursor pagination (`:after`/`:before`/`:limit`/`:order`/`:type`);
  `Store.ETS` is the shipped adapter (an `ordered_set` keyed `{conversation_id, seq}`). Append
  is the only writer.
- `Log` is a GenServer that wraps a store (durability) with in-process subscriber fan-out
  (liveness) and no replay buffer. `subscribe/3` returns the snapshot and registers the
  subscriber in one serialized call, so the snapshot and the live tail partition exactly:
  every item once, no gap, no duplicate. Reconnect with an `:after` cursor.
- `Recorder` bridges `Stream` events into items (tool_use to tool_call, done to message, and
  so on). [Session search](MEMORY.md#session-search) indexes this log.

## Tunnel (reverse co-drive)

`Raxol.Agent.Tunnel` lets a teammate attach to an agent running on your machine over a single
outbound link, without your files or credentials leaving it. The host dials out to a server;
many logical channels multiplex over the one link; when a peer opens a channel, its frames
tunnel to the host, which spawns the channel's handler locally.

- `Frame` has four kinds: `:hello` (host identity, once), `:open`, `:data` (base64 when
  binary), `:close`. Kinds are decoded through a whitelist, never `String.to_atom` on link
  input.
- `Tunnel` is the endpoint GenServer (`role: :host` or `:server`), transport-agnostic:
  outbound frames go through a `send_fun`, inbound bytes arrive as `{:tunnel_recv, binary}`.
- `Tunnel.Link.connect/2` wires two endpoints in-process for tests and same-node co-driving.
  The cross-machine transport (a WebSocket host and server) is a drop-in doing the same two
  things.

## Examples

```bash
FREE_AI=true mix run examples/agents/zero_system.exs  # ZERO System cockpit w/ live LLM reasoning
# framework primitives run from the package (they need Raxol.Agent):
cd packages/raxol_agent && mix run examples/agents/react_agent.exs  # Actions + ReAct + tools + shell
cd packages/raxol_agent && mix run examples/agents/agent_team.exs   # coordinator + workers
```
