# Build Your First Agent

The [Quickstart](QUICKSTART.md) builds a terminal app. This one builds an autonomous
agent: a program an LLM drives, with tools and skills. Same TEA model,
same OTP supervision. The "user" is a model issuing tool calls instead of a keyboard.

By the end you will have an agent that reasons on a real model, calls tools you define,
and reads the skills you give it.

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

Declare which tools an agent may call with `available_actions/0`. The
[Tool Catalog](../reference/TOOL_CATALOG.md) lists every built-in tool and whether
it is sensitive.

```elixir
defmodule MyAgent do
  use Raxol.Agent

  def available_actions, do: [Tools.CountLines]
end
```

A tool marked `sensitive: true` is denied unless the context of the call carries a
`:tool_authorizer` that allows it (`Raxol.Agent.ToolPolicy`). `Raxol.Agent.Stream.react/2`
takes one in its `:context` option; without one a sensitive tool is always denied.

## 3. Reason on a real model

Pick a backend with `ExecutorConfig` and `Backend.Selector`, then drive a turn with
`Raxol.Agent.Stream.react/2`, which runs the reasoning loop and the tool calls:

```elixir
{:ok, backend, backend_opts} =
  Raxol.Agent.Backend.Selector.select(
    Raxol.Agent.ExecutorConfig.new(
      harness: :anthropic,
      model: "claude-sonnet-5",
      auth: %{api_key: System.fetch_env!("ANTHROPIC_API_KEY")}
    )
  )

{:ok, result} =
  "how many lines are in mix.exs?"
  |> Raxol.Agent.Stream.react(
    backend: backend,
    backend_opts: backend_opts,
    actions: MyAgent.available_actions()
  )
  |> Raxol.Agent.Stream.collect()

IO.puts(result.content)
```

`react/2` returns a lazy stream of events (`{:text_delta, text}`, `{:tool_use, call}`,
`{:tool_result, result}`, `{:done, info}`); `collect/1` drains it and returns the final
`{:ok, info}`.

The harness atom selects the provider: `:anthropic`, `:openai`, `:ollama`, `:lm_studio`,
and more. See [Agent Framework](../features/AGENT_FRAMEWORK.md#backends).

## 4. Skills

Skills are opt-in. Start the store through app config:

```elixir
config :raxol_agent,
  skills_provider: Raxol.Agent.Skills.Store,
  skills_root: "~/.raxol/skills"
```

Then name the provider on the agent module and add the skill tools to its actions:

```elixir
defmodule MyAgent do
  use Raxol.Agent

  def available_actions, do: [Tools.CountLines | Raxol.Agent.Actions.Skills.actions()]

  # Read and author SKILL.md procedures.
  def skills_provider, do: Raxol.Agent.Skills.Store
end
```

`Raxol.Agent.Actions.Skills.actions/0` is the three skill tools (`skills_list`, `skill_view`,
`skill_manage`). An agent that does not define `available_actions/0` gets them from
`skills_provider/0` alone. The skill tools read the store from the context of the call, so
pass it to `react/2`:

```elixir
{:ok, result} =
  "which skills do you have?"
  |> Raxol.Agent.Stream.react(
    backend: backend,
    backend_opts: backend_opts,
    actions: MyAgent.available_actions(),
    context: %{skills: Raxol.Agent.Skills.provider_context(MyAgent.skills_provider())}
  )
  |> Raxol.Agent.Stream.collect()
```

- [Skill Authoring](../guides/SKILL_AUTHORING.md): how to write a `SKILL.md`.

## 5. Run a complete example

A full, runnable tool-using agent (with a Mock backend so it works without an API key):

```bash
cd packages/raxol_agent
mix run examples/agents/react_agent.exs                        # Mock backend
ANTHROPIC_API_KEY=sk-ant-... mix run examples/agents/react_agent.exs   # real model
```

## Where next

- [Agent Framework](../features/AGENT_FRAMEWORK.md): teams, backends, authorization, the item-log.
- [Agentic Commerce](../features/AGENTIC_COMMERCE.md): give the agent a wallet and spending limits.
- [Why Raxol](../WHY_RAXOL.md): why an OTP runtime is the right substrate for agents.
