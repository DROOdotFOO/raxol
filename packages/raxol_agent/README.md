# Raxol Agent

AI agent framework for Elixir built on OTP. TEA-based agents with crash isolation, inter-agent messaging, team supervision, and real SSE streaming.

## Install

```elixir
{:raxol_agent, "~> 2.4"}
```

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

## Features

- **TEA-based agents**: `init/update/view` with OTP supervision
- **Agent teams**: Supervisor-based coordinator/worker groups
- **Inter-agent messaging**: Registry-routed messages via `Agent.Comm`
- **Real SSE streaming**: Anthropic, OpenAI, Ollama, Groq, LLM7, OpenRouter, LongCat, Lumo
- **Shell commands**: Port-based execution with result callbacks
- **Headless mode**: `view/1` is optional; skip rendering entirely

## Agent Teams

```elixir
Raxol.Agent.Team.start_link(
  name: :review_team,
  agents: [
    {CodeReviewAgent, id: :reviewer, role: :coordinator},
    {TestRunnerAgent, id: :tester, role: :worker}
  ]
)
```

See [main docs](../../README.md) for full examples and the agent framework guide.
