defmodule Raxol.UI.Components.Harness.ErrorBlock do
  @moduledoc """
  Renders a fault: `error{where, reason}`.

  Distinct error styling -- a red-accented, bordered box -- so a fault reads
  as unmistakably different from a message or reasoning block in the same
  transcript.
  """

  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type t :: %{
          id: String.t() | atom(),
          where: term(),
          reason: term(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id: Ids.default_id(props, "harness-error-block"),
      where: Keyword.get(props, :where, ""),
      reason: Keyword.get(props, :reason, ""),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :harness_error_block)

    %{
      type: :box,
      style: Map.merge(%{border: :single, fg: :red, padding: 1}, base_style),
      children: [
        %{
          type: :column,
          style: %{},
          gap: 0,
          children: [
            Components.text(
              id: "#{state.id}-title",
              content: "Error",
              style: %{bold: true, fg: :red}
            ),
            Components.text(
              id: "#{state.id}-where",
              content: "where: #{display(state.where)}",
              style: %{dim: true}
            ),
            Components.text(
              id: "#{state.id}-reason",
              content: "reason: #{display(state.reason)}",
              style: %{fg: :red}
            )
          ]
        }
      ]
    }
  end

  defp display(text) when is_binary(text), do: text
  defp display(other), do: inspect(other)
end
