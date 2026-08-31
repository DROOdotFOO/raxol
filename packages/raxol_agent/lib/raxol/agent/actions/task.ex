defmodule Raxol.Agent.Actions.Task do
  @moduledoc """
  The `task` Action: delegate a self-contained subtask to a fresh
  read-only sub-agent and return its final answer.

  A sub-agent is a nested `Raxol.Agent.Stream.react/2` run with its own
  clean context and a restricted, **read-only** toolset (`list_dir`,
  `read_file`, `file_stat`, `grep`, `glob`). It deliberately does NOT get
  `write_file`/`edit_file`/`bash` or the `task` tool itself, so a
  delegation can neither mutate the workspace nor recurse without bound.
  The call blocks the parent tool loop until the sub-agent finishes, then
  hands back a concise result — the same shape Claude Code's Task tool has.

  The sub-agent's backend comes from `context[:subagent]` (a map with
  `:executor` / `:backend` / `:backend_opts`), injected by the surface
  running the parent loop, so the sub-agent talks to the same model.

  ## Fanning out

  `prompts` takes a list and runs the delegations concurrently, returning
  one result per prompt in the order given. Independent investigations
  finish in the time of the slowest rather than the sum.

  Each delegation is its own supervised, unlinked process, so one that
  crashes or times out is reported as a failed entry while its siblings
  and the parent turn carry on. Concurrency is capped at four in flight,
  and a fan-out of more than eight prompts is refused rather than silently
  trimmed — every prompt sent is a prompt run, or an error saying it was
  not.
  """

  alias Raxol.Agent.Actions.Code
  alias Raxol.Agent.Actions.Fs
  alias Raxol.Agent.Stream

  # `Stream` above is the agent's, not the stdlib's, and this module is
  # itself named `Task`. Name the stdlib one explicitly so neither reads as
  # the module it is not.
  alias Task, as: ElixirTask

  @default_max_iterations 6
  @max_parallel 4
  @max_prompts 8
  @subagent_timeout_ms 300_000

  defmodule Delegate do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "task",
      description:
        "Delegate a self-contained subtask to a fresh read-only sub-agent " <>
          "and return its final answer. Use for focused investigation " <>
          "(searching, reading, summarizing across many files) that would " <>
          "otherwise clutter the main conversation. The sub-agent has no " <>
          "prior context and cannot write files or run commands: give it " <>
          "everything it needs in the prompt.\n\n" <>
          "Pass `prompt` for one subtask, or `prompts` (up to 8) to run " <>
          "several independent investigations at once — prefer the list " <>
          "whenever the subtasks do not depend on each other, since they " <>
          "run concurrently and come back in the order given.",
      schema: [
        input: [
          prompt: [
            type: :string,
            description: "One self-contained subtask for the sub-agent"
          ],
          prompts: [
            type: {:list, :string},
            description: "Several independent subtasks to run concurrently (max 8)"
          ],
          max_iterations: [
            type: :integer,
            description: "Sub-agent tool-loop guard (default 6)"
          ]
        ],
        output: [
          result: [type: :string],
          results: [type: :list]
        ]
      ]

    @impl true
    def run(params, context) do
      case {Map.get(params, :prompt), Map.get(params, :prompts)} do
        {prompt, nil} when is_binary(prompt) ->
          Raxol.Agent.Actions.Task.run_subagent(prompt, params, context)

        {nil, prompts} when is_list(prompts) ->
          Raxol.Agent.Actions.Task.run_fanout(prompts, params, context)

        {nil, nil} ->
          {:error, :no_prompt}

        {_prompt, _prompts} ->
          {:error, :ambiguous_prompt}
      end
    end
  end

  @doc "All Task actions, for a ReAct run's `actions:`."
  @spec all() :: [module()]
  def all, do: [Delegate]

  @doc false
  @spec run_subagent(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def run_subagent(prompt, params, context) do
    opts = subagent_opts(params, context)
    sink = Map.get(context, :usage_sink)

    prompt
    |> Stream.react(opts)
    |> drain(sink)
    |> case do
      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, %{result: content}}

      {:error, reason} ->
        {:error, {:subagent_failed, reason}}

      _other ->
        {:error, :subagent_no_result}
    end
  end

  @doc false
  @spec run_fanout([String.t()], map(), map()) :: {:ok, map()} | {:error, term()}
  def run_fanout(prompts, params, context) do
    with :ok <- validate_fanout(prompts) do
      results =
        prompts
        |> stream_subagents(params, context)
        |> Enum.zip(prompts)
        |> Enum.with_index(1)
        |> Enum.map(&fanout_entry/1)

      {:ok, %{results: results}}
    end
  end

  defp validate_fanout([]), do: {:error, :no_prompt}

  defp validate_fanout(prompts) when length(prompts) > @max_prompts,
    do: {:error, {:too_many_prompts, length(prompts), @max_prompts}}

  defp validate_fanout(prompts) do
    if Enum.all?(prompts, &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else: {:error, :blank_prompt}
  end

  # Unlinked and supervised where the agent tree is up, so a sub-agent that
  # crashes or wedges is one failed entry rather than a dead parent turn.
  # Without the tree (a bare action call in a test) there is nothing to
  # supervise into, and a linked stream is the honest fallback.
  defp stream_subagents(prompts, params, context) do
    run = fn prompt -> run_subagent(prompt, params, context) end
    opts = [max_concurrency: @max_parallel, timeout: @subagent_timeout_ms, on_timeout: :kill_task]

    case Process.whereis(Raxol.Agent.TaskSupervisor) do
      nil -> ElixirTask.async_stream(prompts, run, opts)
      sup -> ElixirTask.Supervisor.async_stream_nolink(sup, prompts, run, opts)
    end
  end

  defp fanout_entry({{{:ok, {:ok, %{result: result}}}, prompt}, index}),
    do: %{index: index, prompt: prompt, status: "ok", result: result}

  defp fanout_entry({{{:ok, {:error, reason}}, prompt}, index}),
    do: failed(index, prompt, reason)

  defp fanout_entry({{{:exit, :timeout}, prompt}, index}),
    do: failed(index, prompt, :timeout)

  defp fanout_entry({{{:exit, reason}, prompt}, index}),
    do: failed(index, prompt, {:subagent_crashed, reason})

  defp failed(index, prompt, reason) do
    %{index: index, prompt: prompt, status: "error", error: inspect(reason)}
  end

  # `Stream.collect/1` keeps only the final content, so every round's usage --
  # up to max_iterations paid calls against the SAME executor as the parent --
  # died inside the nested stream and reached no ledger. A delegation could
  # therefore overrun a spending cap by an arbitrary multiple while the ledger
  # and /usage both read as barely spent. Drain the stream ourselves and report
  # each round as it lands.
  #
  # Deliberately not halting mid-drain on an exhausted budget: react's after_fun
  # is Process.exit(pid, :normal), a no-op against a non-trapping process, so an
  # early halt would abandon a sub-agent that keeps on spending.
  defp drain(stream, sink) do
    stream
    |> Enum.reduce(nil, fn
      {:turn_complete, info}, acc ->
        report_usage(sink, info)
        acc

      {:done, info}, _acc ->
        report_usage(sink, info)
        {:ok, info}

      {:error, reason}, _acc ->
        {:error, reason}

      _event, acc ->
        acc
    end)
    |> Kernel.||({:error, :no_result})
  end

  defp report_usage(sink, info) when is_function(sink, 1) do
    case Map.get(info, :usage) do
      usage when is_map(usage) and map_size(usage) > 0 ->
        sink.(%{usage: usage, model: Map.get(info, :model)})

      _ ->
        :ok
    end
  end

  defp report_usage(_sink, _info), do: :ok

  defp subagent_opts(params, context) do
    sub = Map.get(context, :subagent, %{})

    [
      actions: Fs.all() ++ Code.read_only(),
      max_iterations: Map.get(params, :max_iterations, @default_max_iterations),
      system_prompt: subagent_system(),
      # A clean context: read-only tools only, default deny_sensitive, and no
      # human-in-the-loop authorizer (a sub-agent must never surface a prompt).
      # BUT it MUST inherit the jail root and marker — dropping :cwd re-roots
      # the sub-agent's read tools at the process-global cwd, which on a hosted
      # host reads outside the tenant's jail (e.g. the SSH host keys). Only
      # those two keys carry over; everything else is deliberately dropped.
      context: subagent_context(context)
    ]
    |> maybe_put(:executor, Map.get(sub, :executor))
    |> maybe_put(:backend, Map.get(sub, :backend))
    |> maybe_put(:backend_opts, Map.get(sub, :backend_opts))
    |> maybe_put(:model, Map.get(sub, :model))
  end

  defp subagent_system do
    "You are a focused sub-agent with read-only tools. Complete the given " <>
      "task by inspecting files, then reply with a concise, self-contained " <>
      "result. Do not ask questions — you have no way to receive answers."
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Carry ONLY the confinement into the nested run: the jail root and its
  # marker. A delegation must never be able to widen its root beyond the
  # parent's, and it must never inherit the authorizer, sub-agent backend, or
  # hooks (kept deliberately absent for a clean deny-by-default read-only run).
  defp subagent_context(context), do: Map.take(context, [:cwd, :jail])
end
