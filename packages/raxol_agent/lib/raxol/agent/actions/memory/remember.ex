defmodule Raxol.Agent.Actions.Memory.Remember do
  @moduledoc "Persist a fact to cross-session memory."

  use Raxol.Agent.Action,
    name: "memory_remember",
    description:
      "Persist a fact to cross-session memory so it can be recalled in future sessions.",
    schema: [
      input: [
        content: [type: :string, required: true, description: "The fact to remember."],
        type: [
          type: :string,
          description: "One of: decision, pattern, gotcha, link, insight, note."
        ],
        tags: [type: {:list, :string}, description: "Optional tags to aid retrieval."]
      ],
      output: [
        id: [type: :string],
        stored: [type: :boolean]
      ]
    ]

  alias Raxol.Agent.Memory.Record

  @impl true
  def run(params, context) do
    case Map.fetch(context, :memory) do
      {:ok, {mod, opts}} -> remember(mod, opts, params)
      :error -> {:error, :memory_not_configured}
    end
  end

  defp remember(mod, opts, params) do
    record =
      Record.new(%{
        content: params.content,
        type: Map.get(params, :type),
        tags: Map.get(params, :tags, []),
        agent_id: Keyword.get(opts, :agent_id)
      })

    case mod.store(record, opts) do
      {:ok, stored} -> {:ok, %{id: stored.id, stored: true}}
      {:error, reason} -> {:error, reason}
    end
  end
end
