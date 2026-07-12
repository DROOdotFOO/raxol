# ReAct Agent Example
#
# Demonstrates the Action + Strategy system introduced in raxol_agent.
# A TEA agent defines reusable Actions (with schema validation), then
# uses the ReAct strategy to let an LLM decide which tools to call.
#
# What you'll learn:
#   - `use Raxol.Agent.Action` to define schema-validated, LLM-callable tools
#   - `Pipeline.run/3` to compose actions sequentially
#   - `Strategy.ReAct` for an LLM reasoning loop with tool use
#   - `run_action/3` and `run_action_async/3` helpers in TEA agents
#   - `Directive.shell/1` to run a shell command; the result arrives as
#     {:command_result, {:shell_result, %{output: ..., exit_status: ...}}}
#   - Mock backend simulates tool calls so this runs without an API key
#
# Default: mock (no API key needed)
# Real AI: ANTHROPIC_API_KEY=sk-ant-... mix run examples/agents/react_agent.exs
#           AI_API_KEY=sk-... mix run examples/agents/react_agent.exs
#
# Controls:
#   1   run actions via Pipeline (sync, no LLM)
#   2   run ReAct loop (LLM decides which tools to call)
#   3   run a shell command as a tool (Directive.shell)
#   q   quit

Logger.configure(level: :warning)

# -- Actions -----------------------------------------------------------------
# Each Action is a reusable, schema-validated module. The schema drives
# both runtime validation and LLM tool definition generation.

defmodule Actions.CountLines do
  use Raxol.Agent.Action,
    name: "count_lines",
    description: "Count lines in a file",
    schema: [
      input: [
        path: [type: :string, required: true, description: "Path to the file"]
      ],
      output: [
        path: [type: :string],
        line_count: [type: :integer]
      ]
    ]

  @impl true
  def run(%{path: path}, _context) do
    case File.read(path) do
      {:ok, content} ->
        lines = content |> String.split("\n") |> length()
        {:ok, %{path: path, line_count: lines}}

      {:error, reason} ->
        {:error, {:file_read_failed, path, reason}}
    end
  end
end

defmodule Actions.FormatReport do
  use Raxol.Agent.Action,
    name: "format_report",
    description: "Format a line count into a human-readable report",
    schema: [
      input: [
        path: [type: :string, required: true, description: "File path"],
        line_count: [
          type: :integer,
          required: true,
          description: "Number of lines"
        ]
      ]
    ]

  @impl true
  def run(%{path: path, line_count: count}, _context) do
    size =
      cond do
        count > 500 -> "large"
        count > 100 -> "medium"
        true -> "small"
      end

    {:ok, %{report: "#{path}: #{count} lines (#{size})", size: size}}
  end
end

defmodule Actions.Summarize do
  use Raxol.Agent.Action,
    name: "summarize",
    description: "Summarize analysis results into a final message",
    schema: [
      input: [
        results: [
          type: :list,
          required: true,
          description: "List of analysis results"
        ]
      ]
    ]

  @impl true
  def run(%{results: results}, _context) do
    summary =
      results
      |> Enum.map_join("\n  ", fn r -> r end)
      |> then(&"Analysis complete:\n  #{&1}")

    {:ok, %{summary: summary}}
  end
end

# -- Backend Configuration --------------------------------------------------

defmodule ReactExample.Config do
  @moduledoc false

  def detect_backend do
    cond do
      key = System.get_env("ANTHROPIC_API_KEY") ->
        {Raxol.Agent.Backend.HTTP,
         provider: :anthropic,
         api_key: key,
         base_url: "https://api.anthropic.com",
         model: System.get_env("ANTHROPIC_MODEL") || "claude-haiku-3-5-20241022",
         max_tokens: 512}

      key = System.get_env("AI_API_KEY") ->
        {Raxol.Agent.Backend.HTTP,
         provider: :openai,
         api_key: key,
         base_url: System.get_env("AI_BASE_URL") || "https://api.openai.com",
         model: System.get_env("AI_MODEL") || "gpt-4o-mini",
         max_tokens: 512}

      true ->
        {Raxol.Agent.Backend.Mock, []}
    end
  end

  def mock_react_opts do
    # Simulate: LLM calls count_lines, then format_report, then gives a text answer
    [
      responses: [
        # Turn 1: LLM wants to count lines
        %{
          content: "",
          tool_calls: [
            %{
              "id" => "call_1",
              "name" => "count_lines",
              "arguments" => %{"path" => "mix.exs"}
            }
          ],
          usage: %{},
          metadata: %{}
        },
        # Turn 2: LLM wants to format the report
        %{
          content: "",
          tool_calls: [
            %{
              "id" => "call_2",
              "name" => "format_report",
              "arguments" => %{"path" => "mix.exs", "line_count" => 82}
            }
          ],
          usage: %{},
          metadata: %{}
        },
        # Turn 3: LLM gives final answer
        %{
          content:
            "I analyzed mix.exs. It has 82 lines, which is a small file. The project configuration looks standard.",
          usage: %{},
          metadata: %{}
        }
      ]
    ]
  end
end

# -- Mock backend that cycles through responses ------------------------------

defmodule ReactExample.SequenceMock do
  @behaviour Raxol.Agent.AIBackend

  @impl true
  def complete(_messages, opts) do
    counter = Keyword.get(opts, :counter)
    responses = Keyword.get(opts, :responses, [])

    if counter do
      idx = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      case Enum.at(responses, idx) do
        nil -> {:ok, %{content: "Done.", usage: %{}, metadata: %{}}}
        response -> {:ok, response}
      end
    else
      {:ok, %{content: "No counter.", usage: %{}, metadata: %{}}}
    end
  end

  @impl true
  def available?, do: true
  @impl true
  def name, do: "Sequence Mock"
  @impl true
  def capabilities, do: [:completion, :tool_use]
end

# -- Agent -------------------------------------------------------------------

defmodule ReactAgent do
  use Raxol.Agent

  alias Raxol.Agent.Action.Pipeline
  alias Raxol.Agent.Strategy.ReAct

  @actions [Actions.CountLines, Actions.FormatReport, Actions.Summarize]

  def available_actions, do: @actions

  @impl true
  def init(_context) do
    {backend_mod, backend_opts} = ReactExample.Config.detect_backend()

    %{
      status: :idle,
      backend: backend_mod,
      backend_opts: backend_opts,
      results: [],
      last_output: nil
    }
  end

  # -- Pipeline demo: sync action composition, no LLM needed -----------------

  @impl true
  def update({:agent_message, _from, :run_pipeline}, model) do
    IO.puts("\n[Pipeline] Running CountLines -> FormatReport on mix.exs...")

    case Pipeline.run(
           [Actions.CountLines, Actions.FormatReport],
           %{path: "mix.exs"},
           %{}
         ) do
      {:ok, result, _commands} ->
        IO.puts("[Pipeline] #{result.report}")

        {%{
           model
           | status: :idle,
             last_output: result.report,
             results: [result.report | model.results]
         }, []}

      {:error, {step, reason}} ->
        IO.puts("[Pipeline] Error in #{inspect(step)}: #{inspect(reason)}")
        {%{model | status: :error}, []}
    end
  end

  # -- ReAct demo: LLM reasoning loop with tool use --------------------------

  def update({:agent_message, _from, :run_react}, model) do
    IO.puts("\n[ReAct] Starting LLM reasoning loop...")

    # Build the strategy context
    {react_backend, react_opts} = build_react_backend(model)

    cmd =
      run_action_async_react(
        "Analyze the file mix.exs. Count its lines and format a report.",
        react_backend,
        react_opts
      )

    {%{model | status: :thinking}, [cmd]}
  end

  # ReAct result arrives here
  def update({:command_result, {:react_done, state}}, model) do
    answer = Map.get(state, :last_answer, "No answer")
    IO.puts("[ReAct] LLM answer: #{answer}")

    tool_results = Map.get(state, :tool_results, [])

    unless tool_results == [] do
      IO.puts("[ReAct] Tool results accumulated: #{length(tool_results)}")
    end

    {%{
       model
       | status: :idle,
         last_output: answer,
         results: [answer | model.results]
     }, []}
  end

  def update({:command_result, {:react_error, reason}}, model) do
    IO.puts("[ReAct] Error: #{inspect(reason)}")
    {%{model | status: :error}, []}
  end

  # -- Shell demo: a tool can be a shell command, run via the agent runtime ---
  # Directive.shell spawns a Port; the result comes back as a command_result.

  def update({:agent_message, _from, :run_shell}, model) do
    IO.puts("\n[Shell] Running `wc -l < mix.exs` via Directive.shell...")
    {%{model | status: :shell}, [Directive.shell("wc -l < mix.exs")]}
  end

  def update({:command_result, {:shell_result, result}}, model) do
    output = String.trim(result.output || "")
    IO.puts("[Shell] exit #{result.exit_status}: #{output}")

    {%{
       model
       | status: :idle,
         last_output: "shell: #{output}",
         results: ["shell: #{output}" | model.results]
     }, []}
  end

  # Keyboard input
  def update(%{type: :key, data: %{key: "1"}}, model) do
    update({:agent_message, :self, :run_pipeline}, model)
  end

  def update(%{type: :key, data: %{key: "2"}}, model) do
    update({:agent_message, :self, :run_react}, model)
  end

  def update(%{type: :key, data: %{key: "3"}}, model) do
    update({:agent_message, :self, :run_shell}, model)
  end

  def update(%{type: :key, data: %{key: "q"}}, model) do
    IO.puts("\nBye!")
    {model, [Directive.stop()]}
  end

  def update(_msg, model), do: {model, []}

  @impl true
  def view(model) do
    column do
      [
        text("ReAct Agent Demo", style: [:bold]),
        text("Status: #{model.status}"),
        text(""),
        text("Press 1 = Pipeline (sync)  2 = ReAct (LLM)  3 = Shell  q = quit"),
        text(""),
        text("Last output: #{model.last_output || "(none)"}")
      ]
    end
  end

  # -- Private ---------------------------------------------------------------

  defp build_react_backend(model) do
    case model.backend do
      Raxol.Agent.Backend.Mock ->
        {:ok, counter} = Agent.start_link(fn -> 0 end)
        mock_opts = ReactExample.Config.mock_react_opts()

        {ReactExample.SequenceMock, Keyword.merge(mock_opts, counter: counter)}

      backend_mod ->
        {backend_mod, model.backend_opts}
    end
  end

  defp run_action_async_react(prompt, backend, backend_opts) do
    Directive.async(fn sender ->
      case ReAct.execute(
             {nil, %{prompt: prompt}},
             %{},
             %{
               backend: backend,
               backend_opts: backend_opts,
               actions: @actions,
               system_prompt:
                 "You are a file analysis agent. Use the available tools to answer questions about files.",
               max_iterations: 5
             }
           ) do
        {:ok, state} -> sender.({:react_done, state})
        {:error, reason} -> sender.({:react_error, reason})
      end
    end)
  end
end

# -- Boot --------------------------------------------------------------------

# Start the agent supervision tree (Registry + DynSup + Orchestrator).
# In production this is started by RaxolAgent.Application; in examples
# and tests we start it manually.
{:ok, _sup} = Raxol.Agent.Supervisor.start_link()

IO.puts("ReAct Agent Demo")
IO.puts("================")

{backend_mod, _} = ReactExample.Config.detect_backend()
IO.puts("Backend: #{inspect(backend_mod)}")
IO.puts("")

# Quick non-interactive demo: run both modes and exit
IO.puts("--- Demo 1: Pipeline (sync action composition) ---")

{:ok, _pid} =
  Raxol.Agent.Session.start_link(
    app_module: ReactAgent,
    id: :react_agent
  )

Raxol.Agent.Session.send_message(:react_agent, :run_pipeline)
Process.sleep(500)

IO.puts("\n--- Demo 2: ReAct (LLM reasoning loop) ---")
Raxol.Agent.Session.send_message(:react_agent, :run_react)
Process.sleep(1500)

IO.puts("\n--- Demo 3: Shell command as a tool (Directive.shell) ---")
Raxol.Agent.Session.send_message(:react_agent, :run_shell)
Process.sleep(500)

IO.puts("\nDone.")
