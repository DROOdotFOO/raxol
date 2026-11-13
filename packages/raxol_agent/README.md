# Raxol Agent

AI agent framework for Elixir built on OTP. TEA-based agents with crash isolation, inter-agent messaging, team supervision, and real SSE streaming.

## Install

```elixir
{:raxol_agent, "~> 2.7"}
```

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

## Features

- **TEA-based agents**: `init/update/view` with OTP supervision
- **Agent teams**: Supervisor-based coordinator/worker groups
- **Inter-agent messaging**: Registry-routed messages via `Agent.Comm`
- **Real SSE streaming**: Anthropic, OpenAI, Ollama, Groq, LLM7, OpenRouter, LongCat, Lumo
- **Shell commands**: Port-based execution with result callbacks
- **Headless mode**: `view/1` is optional; skip rendering entirely

## Agent teams

```elixir
Raxol.Agent.Team.start_link(
  name: :review_team,
  agents: [
    {CodeReviewAgent, id: :reviewer, role: :coordinator},
    {TestRunnerAgent, id: :tester, role: :worker}
  ]
)
```

## Agents over MCP

On a node booted for MCP (`raxol mcp`, `mix mcp.server`: the `:mcp` startup
mode), `Raxol.Agent.McpTools` registers `agent_spawn`, `agent_list`,
`agent_ask`, `agent_status`, `agent_stop` and the resource
`raxol://agent/<id>/journal` with the running `Raxol.MCP.Registry`. In any
other mode that runs the registry, `:full` included, it registers them only
when `mcp_tools` is `true`. The decision is made once per BEAM, when
`Raxol.Agent.McpTools` first starts, so `mcp_tools` belongs in `config/*.exs`:
setting it after `:raxol_agent` has started changes nothing. The tools answer
to the authorizer the node configures (`config :raxol, :mcp_authorizer`).

```elixir
config :raxol_agent,
  mcp_spawnable_apps: [MyAgent],      # default: [Raxol.Agent.Reference.Counter]
  mcp_project_root: "/srv/project",   # default: the working directory
  mcp_exposed_agents: ["ops"],        # agents started elsewhere, by binary id
  mcp_tools: true                     # unset: :mcp mode only; false: never
```

An agent answers `agent_ask` by replying to a `Raxol.Agent.Comm.call/3` whose
message is a string. Its journal is kept per project root and continues when
a stopped id is spawned again with the same app; its state starts from
`init/1`.

`mcp_spawnable_apps` is also the list `raxol acp --agent <app>` serves from
(see [Editor ACP](../../docs/features/EDITOR_ACP.md#serving-your-own-agent)).

See [main docs](../../README.md) for full examples and the agent framework guide.
