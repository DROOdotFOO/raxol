# Build Your First Agent

The [Quickstart](QUICKSTART.md) builds a terminal app. This one builds an autonomous
agent: a program an LLM drives, with tools, memory, and a learning loop. Same TEA model,
same OTP supervision. The "user" is a model issuing tool calls instead of a keyboard.

By the end you will have an agent that reasons on a real model, calls tools you define,
remembers across sessions, and improves itself after each turn.

## 1. A message-driven agent

An agent is a `use Raxol.Agent` module. At its simplest it processes messages and returns
commands, with no LLM at all:

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

This is a headless OTP process (`view/1` defaults to `nil`). See the
[Agent Framework](../features/AGENT_FRAMEWORK.md) for sessions, teams, and messaging.

## 2. Give it tools

A tool is a `use Raxol.Agent.Action` module: a name, a description, a validated input
schema, and a `run/2`. The framework turns it into an LLM tool definition and dispatches
calls to it.

```elixir
defmodule Tools.CountLines do
  use Raxol.Agent.Action,
    name: "count_lines",
    description: "Count the lines in a file.",
    schema: [input: [path: [type: :string, required: true, description: "File path"]]]

  def run(%{path: path}, _context) do
    {:ok, %{lines: path |> File.read!() |> String.split("\n") |> length()}}
  end
end
```

Declare which tools an agent may call with `available_actions/0`. Raxol ships a full
toolset already (file read/write, shell, grep, glob, memory, skills); the
[Tool Catalog](../reference/TOOL_CATALOG.md) lists every built-in tool and its
authorization tier.

```elixir
defmodule MyAgent do
  use Raxol.Agent

  def available_actions do
    [Tools.CountLines | Raxol.Agent.Actions.Fs.all()]
  end
end
```

Sensitive tools (writing files, running shell commands) are denied by default and gated
through the [ALLOW/ASK/DENY authorization engine](../features/AGENT_FRAMEWORK.md#authorization-allowaskdeny).
The [Coding Agent](../features/CODING_AGENT.md) shows the interactive approval UX.

## 3. Reason on a real model

Pick a backend with `ExecutorConfig` and `Backend.Selector`, then drive a turn with
`Raxol.Agent.Turn`, which runs the reasoning loop and records the conversation:

```elixir
{:ok, log} = Raxol.Agent.Conversation.Log.start_link(name: MyLog)

{:ok, backend, backend_opts} =
  Raxol.Agent.Backend.Selector.select(
    Raxol.Agent.ExecutorConfig.new(
      harness: :anthropic,
      model: "claude-sonnet-5",
      auth: %{api_key: System.fetch_env!("ANTHROPIC_API_KEY")}
    )
  )

{:ok, items} =
  Raxol.Agent.Turn.run(MyAgent, "how many lines are in mix.exs?",
    backend: backend,
    backend_opts: backend_opts,
    log: MyLog,
    conversation_id: "session-1",
    agent_id: "my-agent"
  )
```

The harness atom selects the provider: `:anthropic`, `:openai`, `:ollama`, `:lm_studio`,
`:claude_native` (Claude Code), `:cursor`, and more. See
[Agent Framework](../features/AGENT_FRAMEWORK.md#native-multi-vendor-harness).

## 4. Memory, skills, and self-improvement

These are opt-in callbacks on the agent module. Turn wires them into every turn:

```elixir
defmodule MyAgent do
  use Raxol.Agent

  # Recall facts across sessions, and search prior conversation history.
  def memory_providers, do: [Raxol.Agent.Memory.Store.Ets]

  # Author and reuse SKILL.md procedures.
  def skills_provider, do: Raxol.Agent.Skills.Store

  # After each successful turn, review it on a cheap model and write down
  # what was learned (durable memory + new skills).
  def self_improve, do: %{enabled: true, model: "claude-haiku-4-5", min_tool_calls: 5}

  def available_actions, do: Raxol.Agent.Actions.Fs.all()
end
```

Setting `memory_providers/0` and `skills_provider/0` auto-exposes the memory and skills
tools. `self_improve/0` runs a background reviewer after each turn (isolated, so a review
crash never touches the turn). Nothing else changes: the same `Turn.run/3` call now
recalls memory, offers skills, and learns.

- [Memory](../features/MEMORY.md): the provider stack, session search, and user model.
- [Self-Improvement](../features/SELF_IMPROVEMENT.md): the after-turn loop and the Curator.
- [Skill Authoring](../guides/SKILL_AUTHORING.md): how to write a `SKILL.md`.

## 5. Run a complete example

A full, runnable tool-using agent (with a Mock backend so it works without an API key):

```bash
cd packages/raxol_agent
mix run examples/agents/react_agent.exs                        # Mock backend
ANTHROPIC_API_KEY=sk-ant-... mix run examples/agents/react_agent.exs   # real model
```

For an interactive coding agent you can talk to right now, see the
[Coding Agent](../features/CODING_AGENT.md) (`mix raxol.code`).

## Where next

- [Agent Framework](../features/AGENT_FRAMEWORK.md): teams, the native harness, the item-log, the tunnel.
- [Agentic Commerce](../features/AGENTIC_COMMERCE.md): give the agent a wallet and spending limits.
- [Why Raxol](../WHY_RAXOL.md): why an OTP runtime is the right substrate for agents.
