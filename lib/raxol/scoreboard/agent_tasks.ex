defmodule Raxol.Scoreboard.AgentTasks do
  @moduledoc """
  "Can an AI use your app?", measured without a model: five playground tasks,
  each solved two ways, counted in calls and bytes.

  Every task is solved by its canonical **tool path**, the app's derived MCP
  tools (`Raxol.MCP.TreeWalker` derives them, the session's
  `Raxol.MCP.ToolSynchronizer` registers them), and by its canonical **key
  path**, keystrokes through `Raxol.Headless.send_key_and_screenshot/3`, the
  call behind the `raxol_send_key` tool, which answers a screenshot per key.
  Both must leave the app's model in the task's goal state.

  What an agent reads and writes stands in for tokens (bytes, not a
  tokenizer's count):

    * tool path: the session's tool list as `tools/list` serves it (name,
      description, input schema, annotations; JSON, sorted by name), then per
      call the request `{"name", "arguments"}` as JSON and the result's text;
    * key path: one screenshot to see the screen, then per key the
      `raxol_send_key` request as JSON and the screenshot it answers.

  Per task the metrics are `agent.<task>.tool_calls`, `.tool_bytes`,
  `.key_calls` and `.key_bytes`, lower is better, exact.

  Inputs are pinned so two runs give the same bytes: one fixed session id
  (it is part of every derived tool name), a fixed screen size, and
  `subscriptions: false` (no timer advances a model between steps). Each
  path starts a fresh session, so neither path sees the other's state or
  tool set. A task's `:setup` keys (opening the modal) run before the path
  and are not counted.

  `run/1` starts its own runtime in a fresh process and stops it at the end:
  a supervisor over a private `Raxol.MCP.Registry` and `Raxol.MCP.Server`,
  plus `Raxol.Headless` when it is not already running (`mix
  raxol.scoreboard` only configures the application, it does not start it).
  Tools are listed and called on that registry directly, never through a
  transport.
  """

  alias Raxol.Headless
  alias Raxol.MCP.{Registry, Server}

  alias Raxol.Playground.Demos.{
    ModalDemo,
    SelectListDemo,
    TableDemo,
    TabsDemo,
    TextInputDemo
  }

  @session "s1"
  @width 80
  @height 24
  @registry :raxol_scoreboard_agent_registry
  @server :raxol_scoreboard_agent_server

  @typedoc """
  A task: its `:name` (the metric id segment), the `:app` it runs, `:setup`
  keys sent before either path, the `:tool_path` as `{tool, arguments}`
  calls (`tool` without the session prefix), the `:key_path` keys (a
  character or a special key atom such as `:enter`), and the `:goal`: every
  `{keys, value}` pair must hold of the app's model after the path, `keys`
  leading from the model to the field.
  """
  @type agent_task :: %{
          name: String.t(),
          app: module(),
          setup: [String.t() | atom()],
          tool_path: [{String.t(), map()}],
          key_path: [String.t() | atom()],
          goal: [{[atom()], term()}]
        }

  @typedoc """
  One path's outcome: the calls it made and every byte stream it counted,
  in order, or why it failed (a failed path is not measured).
  """
  @type outcome ::
          {:ok, %{calls: non_neg_integer(), stream: [binary()]}}
          | {:error, String.t()}

  @type result :: %{name: String.t(), tool: outcome(), key: outcome()}

  @tasks [
    %{
      name: "table_sort_stars_desc",
      app: TableDemo,
      setup: [],
      tool_path: [
        {"playground_table.sort", %{"column" => "stars", "direction" => "desc"}}
      ],
      # `s` steps from no sort through each column ascending, then descending.
      key_path: List.duplicate("s", 8),
      goal: [{[:table, :sort_by], :stars}, {[:table, :sort_direction], :desc}]
    },
    %{
      name: "select_list_pick",
      app: SelectListDemo,
      setup: [],
      tool_path: [{"lang.select", %{"index" => 3}}],
      key_path: ["o", "j", "j", "j", :enter],
      goal: [{[:confirmed], "Python"}, {[:open], false}]
    },
    %{
      name: "modal_dismiss",
      app: ModalDemo,
      setup: ["o"],
      tool_path: [{"confirm.dismiss", %{}}],
      key_path: [:escape],
      goal: [{[:show], false}, {[:cancelled], 1}, {[:confirmed], 0}]
    },
    %{
      name: "text_input_fill",
      app: TextInputDemo,
      setup: [],
      tool_path: [{"input.type_into", %{"text" => "hello"}}],
      key_path: ["h", "e", "l", "l", "o"],
      goal: [{[:value], "hello"}]
    },
    %{
      name: "tabs_switch",
      app: TabsDemo,
      setup: [],
      tool_path: [{"tabs.select_tab", %{"index" => 2}}],
      key_path: ["3"],
      goal: [{[:active], 2}]
    }
  ]

  @doc "The five benchmark tasks."
  @spec tasks() :: [agent_task()]
  def tasks, do: @tasks

  @doc """
  Runs `tasks` and answers `{metrics, failures}`: the metrics of every path
  that reached its goal, and one line per path that did not, which is left
  out of the metrics.
  """
  @spec collect([agent_task()]) ::
          {%{String.t() => non_neg_integer()}, [String.t()]}
  def collect(tasks \\ tasks()) do
    results = run(tasks)
    {metrics(results), failures(results)}
  end

  @doc "The metrics of `results`' successful paths."
  @spec metrics([result()]) :: %{String.t() => non_neg_integer()}
  def metrics(results) do
    for %{name: name} = result <- results,
        path <- [:tool, :key],
        {:ok, %{calls: calls, stream: stream}} <- [Map.fetch!(result, path)],
        {metric, value} <- [
          calls: calls,
          bytes: Enum.sum_by(stream, &byte_size/1)
        ],
        into: %{},
        do: {"agent.#{name}.#{path}_#{metric}", value}
  end

  defp failures(results) do
    for %{name: name} = result <- results,
        path <- [:tool, :key],
        {:error, why} <- [Map.fetch!(result, path)],
        do: "agent task #{name}: the #{path} path #{why}; not measured"
  end

  @doc """
  Runs every task's tool path and key path in a runtime started for the run
  in a fresh process (see the module doc), and stops it.
  """
  @spec run([agent_task()]) :: [result()]
  def run(tasks \\ tasks()) do
    fn ->
      with_runtime(fn registry -> Enum.map(tasks, &run_task(&1, registry)) end)
    end
    |> Task.async()
    |> Task.await(:infinity)
  end

  defp with_runtime(fun) do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)
    {:ok, sup} = Supervisor.start_link([], strategy: :rest_for_one)

    try do
      {:ok, registry} =
        Supervisor.start_child(
          sup,
          {Registry, name: @registry, server: @server}
        )

      # Calls go to the pid: Registry caches a named registry's table for
      # good, and this one is started again on every run.
      {:ok, _server} =
        Supervisor.start_child(sup, {Server, name: @server, registry: registry})

      :ok = maybe_start_headless(sup)
      fun.(registry)
    after
      Supervisor.stop(sup)
    end
  end

  defp maybe_start_headless(sup) do
    case Process.whereis(Headless) do
      nil ->
        {:ok, _headless} =
          Supervisor.start_child(sup, {Headless, name: Headless})

        :ok

      _running ->
        :ok
    end
  end

  defp run_task(task, registry) do
    %{
      name: task.name,
      tool: in_session(task, registry, &tool_path(&1, registry)),
      key: in_session(task, registry, &key_path/1)
    }
  end

  defp in_session(task, registry, path) do
    opts = [
      id: @session,
      width: @width,
      height: @height,
      subscriptions: false,
      registry: registry,
      server: @server
    ]

    case Headless.start(task.app, opts) do
      {:ok, @session} ->
        try do
          with :ok <- setup(task.setup),
               {:ok, measured} <- path.(task),
               :ok <- check_goal(task.goal) do
            {:ok, measured}
          end
        after
          Headless.stop(@session)
        end

      {:error, reason} ->
        {:error, "could not start #{inspect(task.app)}: #{inspect(reason)}"}
    end
  end

  defp setup(keys) do
    keys
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case Headless.send_key(@session, key) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "setup key #{inspect(key)}: #{inspect(reason)}"}}
      end
    end)
    |> settled()
  end

  # The tool set includes every tool the setup's last frame derives.
  defp settled(:ok) do
    case Headless.settle(@session) do
      :ok -> :ok
      {:error, reason} -> {:error, "settle failed: #{inspect(reason)}"}
    end
  end

  defp settled(error), do: error

  defp tool_path(task, registry) do
    listing =
      registry
      |> Registry.list_tools()
      |> Enum.sort_by(& &1.name)
      |> Jason.encode!()

    task.tool_path
    |> Enum.reduce_while({:ok, [listing]}, fn {tool, arguments},
                                              {:ok, stream} ->
      name = "#{@session}.#{tool}"
      request = Jason.encode!(%{"name" => name, "arguments" => arguments})

      case Registry.call_tool(registry, name, arguments) do
        {:ok, content} ->
          {:cont, {:ok, [content_text(content), request | stream]}}

        {:error, reason} ->
          {:halt, {:error, "call #{name} failed: #{inspect(reason)}"}}
      end
    end)
    |> measured(length(task.tool_path))
  end

  defp key_path(task) do
    with {:ok, screen} <- screenshot() do
      task.key_path
      |> Enum.reduce_while({:ok, [screen]}, &key_step/2)
      |> measured(length(task.key_path))
    end
  end

  defp key_step(key, {:ok, stream}) do
    case send_key(key) do
      {:ok, request, screen} -> {:cont, {:ok, [screen, request | stream]}}
      error -> {:halt, error}
    end
  end

  # `raxol_send_key`'s request and the screenshot it answers.
  defp send_key(key) do
    arguments = %{"id" => @session, "key" => to_string(key)}

    request =
      Jason.encode!(%{"name" => "raxol_send_key", "arguments" => arguments})

    case Headless.send_key_and_screenshot(@session, key) do
      {:ok, screen} ->
        {:ok, request, screen}

      {:error, reason} ->
        {:error, "key #{inspect(key)} failed: #{inspect(reason)}"}
    end
  end

  defp screenshot do
    case Headless.screenshot(@session) do
      {:ok, screen} -> {:ok, screen}
      {:error, reason} -> {:error, "screenshot failed: #{inspect(reason)}"}
    end
  end

  defp measured({:ok, stream}, calls),
    do: {:ok, %{calls: calls, stream: Enum.reverse(stream)}}

  defp measured(error, _calls), do: error

  defp content_text(content),
    do: Enum.map_join(content, &Map.get(&1, :text, ""))

  defp check_goal(goal) do
    case Headless.get_model(@session) do
      {:ok, model} ->
        if reached?(model, goal),
          do: :ok,
          else: {:error, "does not reach its goal"}

      {:error, reason} ->
        {:error, "model read failed: #{inspect(reason)}"}
    end
  end

  # `get_in/2` cannot read a struct field, and a model may hold structs.
  defp reached?(model, goal) do
    Enum.all?(goal, fn {keys, value} ->
      Enum.reduce(keys, model, &Map.get(&2, &1)) == value
    end)
  end
end
