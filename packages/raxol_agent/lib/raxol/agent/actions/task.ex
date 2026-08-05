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
  """

  alias Raxol.Agent.Actions.Code
  alias Raxol.Agent.Actions.Fs
  alias Raxol.Agent.Stream

  @default_max_iterations 6

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
          "everything it needs in `prompt`.",
      schema: [
        input: [
          prompt: [
            type: :string,
            required: true,
            description: "The self-contained subtask for the sub-agent"
          ],
          max_iterations: [
            type: :integer,
            description: "Sub-agent tool-loop guard (default 6)"
          ]
        ],
        output: [
          result: [type: :string]
        ]
      ]

    @impl true
    def run(%{prompt: prompt} = params, context) do
      Raxol.Agent.Actions.Task.run_subagent(prompt, params, context)
    end
  end

  @doc "All Task actions, for a ReAct run's `actions:`."
  @spec all() :: [module()]
  def all, do: [Delegate]

  @doc false
  @spec run_subagent(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def run_subagent(prompt, params, context) do
    opts = subagent_opts(params, context)

    prompt
    |> Stream.react(opts)
    |> Stream.collect()
    |> case do
      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, %{result: content}}

      {:error, reason} ->
        {:error, {:subagent_failed, reason}}

      _other ->
        {:error, :subagent_no_result}
    end
  end

  defp subagent_opts(params, context) do
    sub = Map.get(context, :subagent, %{})

    [
      actions: Fs.all() ++ Code.read_only(),
      max_iterations: Map.get(params, :max_iterations, @default_max_iterations),
      system_prompt: subagent_system(),
      # A clean context: read-only tools only, default deny_sensitive, and no
      # human-in-the-loop authorizer (a sub-agent must never surface a prompt).
      context: %{}
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
end
