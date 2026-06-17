defmodule Raxol.Agent.Actions.SessionSearch do
  @moduledoc "Search past conversation history for raw messages relevant to a query."

  use Raxol.Agent.Action,
    name: "session_search",
    description:
      "Search prior conversation history (raw messages and tool results) for items " <>
        "relevant to a query. Returns the actual messages, not summaries.",
    schema: [
      input: [
        query: [type: :string, required: true, description: "What to search for."],
        limit: [type: :integer, description: "Maximum results (default 10)."],
        conversation_id: [type: :string, description: "Restrict to one conversation."]
      ],
      output: [
        results: [type: :list]
      ]
    ]

  @impl true
  def run(params, context) do
    case Map.fetch(context, :session_search) do
      {:ok, {mod, opts}} -> {:ok, %{results: run_search(mod, opts, params)}}
      :error -> {:error, :session_search_not_configured}
    end
  end

  defp run_search(mod, opts, params) do
    search_opts =
      opts
      |> put_opt(:limit, Map.get(params, :limit))
      |> put_opt(:conversation_id, Map.get(params, :conversation_id))

    server = Keyword.get(opts, :server, mod)

    server
    |> mod.search(params.query, search_opts)
    |> Enum.map(&format/1)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp format(item) do
    data = Map.get(item, :data, %{})

    %{
      id: Map.get(item, :id),
      conversation_id: Map.get(item, :conversation_id),
      seq: Map.get(item, :seq),
      type: Map.get(item, :type),
      content: Map.get(data, :content) || Map.get(data, :text) || ""
    }
  end
end
