defmodule Raxol.Agent.Actions.Memory.Forget do
  @moduledoc "Delete a memory by its id."

  use Raxol.Agent.Action,
    name: "memory_forget",
    description: "Delete a memory by its id.",
    schema: [
      input: [
        id: [type: :string, required: true, description: "The memory id to forget."]
      ],
      output: [
        forgotten: [type: :boolean]
      ]
    ]

  @impl true
  def run(%{id: id}, context) do
    case Map.fetch(context, :memory) do
      {:ok, {mod, opts}} ->
        :ok = mod.forget(id, opts)
        {:ok, %{forgotten: true}}

      :error ->
        {:error, :memory_not_configured}
    end
  end
end
