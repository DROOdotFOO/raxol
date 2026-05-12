# Agent Framework

An agent is a TEA module where input comes from LLMs and tools instead of a keyboard. Same `init/update/view` loop, same OTP supervision, same crash isolation -- the "user" is an AI model issuing commands and processing results.

For agent payment capabilities (wallets, spending controls, cross-chain transfers), see [Agentic Commerce](AGENTIC_COMMERCE.md).

## Quick Start

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

## How It Works

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

## Agent Session

`Raxol.Agent.Session` is the GenServer hosting a single agent. It wraps `Lifecycle` with `environment: :agent`, which skips the terminal driver and plugin manager.

```elixir
# Start an agent
{:ok, _pid} = Raxol.Agent.Session.start_link(
  id: :code_reviewer,
  app_module: CodeReviewAgent
)

# Send a message (async -- arrives as {:agent_message, from, payload} in update/2)
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
# Arrives as {:team_broadcast, :my_team, {:status_update, status}}
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

## Command Types

Commands returned from `update/2` are processed by Lifecycle:

| Command    | Helper                        | Result in update/2                                                   |
| ---------- | ----------------------------- | -------------------------------------------------------------------- |
| Async      | `async(fn sender -> ... end)` | `{:command_result, {:async_result, value}}`                          |
| Shell      | `shell("ls -la")`             | `{:command_result, {:shell_result, %{output: ..., exit_code: ...}}}` |
| Send Agent | `send_agent(:target, msg)`    | Delivered to target as `{:agent_message, from, msg}`                 |

## Headless Agents

When `view/1` returns `nil` (the default), no rendering happens. The agent is a pure message-processing loop, good for background workers, data pipelines, or agents that only talk to other agents.

## AI Backend Streaming

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

Supports Anthropic, OpenAI, Ollama, Proton's Lumo, and Kimi 2.5/moonshot.
Provider is auto-detected from `:base_url` or set via `:provider`.

Backend detection tries each in order: Lumo -> Anthropic -> Kimi -> OpenAI -> Ollama -> LLM7 -> Mock. Set `FREE_AI=true` to hit LLM7.io with no API key.

## Examples

```bash
mix run examples/agents/code_review_agent.exs    # single agent, shell commands
mix run examples/agents/agent_team.exs            # coordinator + workers
FREE_AI=true mix run examples/agents/ai_cockpit.exs  # multi-agent cockpit w/ real LLM
```
