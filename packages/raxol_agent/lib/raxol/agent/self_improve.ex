defmodule Raxol.Agent.SelfImprove do
  @moduledoc """
  After-turn background curation: review a completed agent turn and persist
  durable knowledge without touching the live conversation.

  When a `react/2` turn finishes and the runtime has drained it into the
  `Conversation.Log` (via `Raxol.Agent.Conversation.Recorder.record_stream/4`),
  the runtime calls `after_turn/3` with the turn's items, the configured write
  targets, and the agent's `self_improve/0` config. If the turn qualifies (it
  succeeded and did at least `min_tool_calls` tool calls), an unlinked `Task`
  reviews it on an auxiliary model and writes what is worth keeping:

    * facts -> `Raxol.Agent.Memory` (semantic memory)
    * reusable procedures -> `Raxol.Agent.Skills.Store`, tagged `created_by:
      :agent` so the Curator may later age or consolidate them.

  The reviewer runs in its own process with its own model call. It can only
  append to memory and the skill store; it never calls `update/2`, never mutates
  the live conversation, and a crash in it is logged, not propagated.

  ## Config (the `self_improve/0` map)

      %{
        enabled: true,
        backend: Raxol.Agent.Backend.HTTP,   # an AIBackend; defaults to Mock
        model: "claude-haiku-4-5",           # auxiliary (cheap) model
        backend_opts: [],                    # extra opts passed to complete/2
        min_tool_calls: 5                    # complexity gate (default 5)
      }

  ## Writers

  `writers` mirrors the agent's tool context:
  `%{memory: {mod, opts} | nil, skills: {mod, opts} | nil}` (the same tuples
  `Raxol.Agent.Memory.provider_context/3` and
  `Raxol.Agent.Skills.provider_context/2` build). Either may be absent; the
  reviewer simply skips that write target.
  """

  require Logger

  alias Raxol.Agent.Auxiliary
  alias Raxol.Agent.Memory.Record

  @default_min_tool_calls 5
  @default_backend Raxol.Agent.Backend.Mock

  @type writers :: %{
          optional(:memory) => {module(), keyword()} | nil,
          optional(:skills) => {module(), keyword()} | nil
        }

  @system_prompt """
  You are a curation reviewer. You are shown the transcript of one completed
  agent turn. Decide what is worth keeping for future sessions:

  - durable facts the agent learned (preferences, conventions, results) -> memories
  - reusable multi-step procedures the agent worked out -> skills

  Respond with ONLY a JSON object, no prose, of this shape:

  {"memories": [{"content": "...", "type": "insight", "tags": ["..."]}],
   "skills": [{"name": "kebab-name", "description": "one line",
               "category": "optional", "body": "# Title\\n\\nmarkdown steps"}]}

  Use empty arrays when nothing is worth keeping. Prefer keeping little.
  """

  @doc """
  Entry point the runtime calls after recording a turn.

  Returns `:spawned` when a background review was started, `:skipped`
  otherwise (disabled, or the turn did not qualify).
  """
  @spec after_turn([map()], writers(), map() | nil) :: :spawned | :skipped
  def after_turn(items, writers, config)
  def after_turn(_items, _writers, nil), do: :skipped

  def after_turn(items, writers, %{enabled: true} = config) do
    if qualifies?(items, config) do
      spawn_review(items, writers, config)
      :spawned
    else
      :skipped
    end
  end

  def after_turn(_items, _writers, _config), do: :skipped

  @doc """
  Whether a turn qualifies for review: it succeeded (no error item) and did at
  least `min_tool_calls` tool calls (default 5).
  """
  @spec qualifies?([map()], map()) :: boolean()
  def qualifies?(items, config) do
    min = Map.get(config, :min_tool_calls, @default_min_tool_calls)
    no_error?(items) and count_tool_calls(items) >= min
  end

  @doc """
  Run the review synchronously: format the turn, ask the auxiliary model what to
  keep, and apply the writes. Returns `{:ok, %{memories: n, skills: n}}` with the
  counts written, or `{:error, reason}`. Public so it can be driven directly in
  tests; production goes through `after_turn/3`.
  """
  @spec review([map()], writers(), map()) ::
          {:ok, %{memories: non_neg_integer(), skills: non_neg_integer()}}
          | {:error, term()}
  def review(items, writers, config) do
    {backend, opts} = resolve_backend(config)
    messages = build_messages(items)

    with {:ok, response} <- backend.complete(messages, opts),
         {:ok, decision} <- parse_decision(response) do
      {:ok,
       %{
         memories: apply_memories(decision, writers),
         skills: apply_skills(decision, writers)
       }}
    end
  end

  # -- gating -----------------------------------------------------------------

  defp count_tool_calls(items), do: Enum.count(items, &(Map.get(&1, :type) == :tool_call))

  defp no_error?(items), do: not Enum.any?(items, &(Map.get(&1, :type) == :error))

  # -- spawning ---------------------------------------------------------------

  defp spawn_review(items, writers, config) do
    Task.start(fn ->
      try do
        review(items, writers, config)
      rescue
        error -> Logger.warning("self-improve review crashed: #{inspect(error)}")
      end
    end)
  end

  # -- prompt -----------------------------------------------------------------

  defp build_messages(items) do
    [
      %{role: :system, content: @system_prompt},
      %{role: :user, content: transcript(items)}
    ]
  end

  defp transcript(items), do: Enum.map_join(items, "\n", &line/1)

  defp line(item) do
    case Map.get(item, :type) do
      :message ->
        "#{role(item)}: #{get(item, :content)}"

      :tool_call ->
        "tool_call #{get(item, :name)}(#{inspect(get(item, :arguments))})"

      :tool_result ->
        "tool_result #{get(item, :name)} -> #{truncate(inspect(get(item, :result)))}"

      :error ->
        "error: #{get(item, :reason)}"

      other ->
        "#{other}: #{inspect(Map.get(item, :data))}"
    end
  end

  defp role(item), do: get(item, :role) || Map.get(item, :created_by) || "?"
  defp get(item, key), do: item |> Map.get(:data, %{}) |> Map.get(key)

  defp truncate(string) when byte_size(string) > 500, do: binary_part(string, 0, 500) <> "..."
  defp truncate(string), do: string

  # -- model call -------------------------------------------------------------

  defp backend_opts(config) do
    base = Map.get(config, :backend_opts, [])

    case Map.get(config, :model) do
      nil -> base
      model -> Keyword.put(base, :model, model)
    end
  end

  # An explicit backend or model wins. Otherwise route curation through the
  # auxiliary resolver, degrading to the default backend if no slot is available.
  defp resolve_backend(config) do
    if Map.has_key?(config, :backend) or Map.has_key?(config, :model) do
      {Map.get(config, :backend, @default_backend), backend_opts(config)}
    else
      base = Map.get(config, :backend_opts, [])

      case Auxiliary.select(:curation, aux_opts(config)) do
        {:ok, module, opts} -> {module, Keyword.merge(base, opts)}
        {:error, _reason} -> {@default_backend, base}
      end
    end
  end

  defp aux_opts(config) do
    [
      auxiliary: Map.get(config, :auxiliary),
      default: Map.get(config, :default),
      available?: Map.get(config, :available?)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # -- decision parsing -------------------------------------------------------

  defp parse_decision(%{content: content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> parse_embedded(content)
    end
  end

  defp parse_decision(_), do: {:error, :no_content}

  # The model may wrap JSON in prose or a code fence; recover the object between
  # the first `{` and the last `}`.
  defp parse_embedded(content) do
    with start when start != nil <- index_of(content, "{"),
         stop when stop != nil <- last_index_of(content, "}"),
         slice = binary_part(content, start, stop - start + 1),
         {:ok, map} when is_map(map) <- Jason.decode(slice) do
      {:ok, map}
    else
      _ -> {:error, :invalid_decision}
    end
  end

  defp index_of(string, char) do
    case :binary.match(string, char) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  defp last_index_of(string, char) do
    case :binary.matches(string, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # -- write application ------------------------------------------------------

  defp apply_memories(decision, %{memory: {mod, opts}}) when is_atom(mod) do
    decision
    |> Map.get("memories", [])
    |> Enum.count(&store_memory(mod, opts, &1))
  end

  defp apply_memories(_decision, _writers), do: 0

  defp store_memory(mod, opts, %{"content" => content} = mem) when is_binary(content) do
    record =
      Record.new(%{
        content: content,
        type: Map.get(mem, "type"),
        tags: Map.get(mem, "tags", []),
        agent_id: Keyword.get(opts, :agent_id)
      })

    match?({:ok, _}, mod.store(record, opts))
  end

  defp store_memory(_mod, _opts, _mem), do: false

  defp apply_skills(decision, %{skills: {mod, opts}}) when is_atom(mod) do
    decision
    |> Map.get("skills", [])
    |> Enum.count(&create_skill(mod, opts, &1))
  end

  defp apply_skills(_decision, _writers), do: 0

  defp create_skill(mod, opts, %{"name" => name} = skill) when is_binary(name) do
    attrs = %{
      name: name,
      description: Map.get(skill, "description"),
      category: Map.get(skill, "category"),
      body: Map.get(skill, "body", ""),
      created_by: :agent
    }

    match?({:ok, _}, mod.create(attrs, opts))
  end

  defp create_skill(_mod, _opts, _skill), do: false
end
