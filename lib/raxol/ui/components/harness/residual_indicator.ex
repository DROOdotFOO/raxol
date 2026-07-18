defmodule Raxol.UI.Components.Harness.ResidualIndicator do
  @moduledoc """
  A read-only indicator for the harness's residual projection.

  Renders the `%{description}` payload of a `residual` meta event (source
  `:probe_c2_residual`) -- the named unknown the probe swarm hasn't resolved
  yet. Renders a subtle warning line when a residual is outstanding, and
  renders nothing when it's `nil` (resolved / never raised).
  """

  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type t :: %{
          id: String.t() | atom(),
          residual: String.t() | nil,
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "residual-indicator-#{:erlang.unique_integer([:positive])}"
        ),
      residual: Keyword.get(props, :residual, nil),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :residual_indicator)

    line(state, base_style)
  end

  defp line(%{residual: nil}, _base_style) do
    Components.text(content: "")
  end

  defp line(%{id: id, residual: residual}, base_style) do
    Components.text(
      id: id,
      content: "⚠ unresolved: #{residual}",
      style: Map.merge(%{dim: true}, base_style)
    )
  end
end
