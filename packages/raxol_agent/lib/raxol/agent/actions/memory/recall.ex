defmodule Raxol.Agent.Actions.Memory.Recall do
  @moduledoc "Search cross-session memory for facts relevant to a query."

  use Raxol.Agent.Action,
    name: "memory_recall",
    description: "Search cross-session memory for facts relevant to a query.",
    schema: [
      input: [
        query: [type: :string, required: true, description: "What to recall."],
        limit: [type: :integer, description: "Maximum results (default 5)."]
      ],
      output: [
        results: [type: :list]
      ]
    ]

  @impl true
  def run(params, context) do
    case Map.fetch(context, :memory) do
      {:ok, {mod, opts}} -> recall(mod, opts, params)
      :error -> {:error, :memory_not_configured}
    end
  end

  defp recall(mod, opts, params) do
    opts = maybe_limit(opts, params)
    records = mod.search(params.query, opts)
    {:ok, %{results: Enum.map(records, &format/1)}}
  end

  defp maybe_limit(opts, %{limit: limit}) when is_integer(limit),
    do: Keyword.put(opts, :limit, limit)

  defp maybe_limit(opts, _params), do: opts

  defp format(record) do
    %{id: record.id, content: record.content, type: record.type, tags: record.tags}
  end
end
