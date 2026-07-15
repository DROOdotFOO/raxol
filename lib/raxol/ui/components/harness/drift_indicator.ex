defmodule Raxol.UI.Components.Harness.DriftIndicator do
  @moduledoc """
  Cross-family drift verdict gauge: how far this run has drifted from its
  originating agent family, on a 0 (identical) to 100 (fully drifted) scale.

  Uses the same green -> yellow -> red gauge idiom as
  `Raxol.UI.Components.Harness.ContextMeter` and
  `Raxol.UI.Components.Harness.SpendMeter`.
  """

  alias Raxol.UI.Components.Progress.Bar
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type t :: %{
          id: String.t() | atom(),
          score: number(),
          family: String.t(),
          width: pos_integer(),
          warn_threshold: number(),
          danger_threshold: number(),
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
          "drift-indicator-#{:erlang.unique_integer([:positive])}"
        ),
      score: Keyword.get(props, :score, 0),
      family: Keyword.get(props, :family, ""),
      width: Keyword.get(props, :width, 20),
      warn_threshold: Keyword.get(props, :warn_threshold, 50),
      danger_threshold: Keyword.get(props, :danger_threshold, 75),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :drift_indicator)

    clamped = state.score |> max(0) |> min(100)
    color = gauge_color(clamped, state.warn_threshold, state.danger_threshold)
    bar_string = Bar.bar(clamped, max: 100, width: state.width, style: :blocks)

    %{
      type: :row,
      style: base_style,
      children: [
        Raxol.View.Components.text(
          id: "#{state.id}-label",
          content: "Drift ",
          style: %{bold: true}
        ),
        Raxol.View.Components.text(
          id: "#{state.id}-bar",
          content: bar_string,
          fg: color
        ),
        Raxol.View.Components.text(
          id: "#{state.id}-family",
          content: " #{state.family}",
          style: %{dim: true}
        )
      ]
    }
  end

  defp gauge_color(score, _warn, danger) when score >= danger, do: :red
  defp gauge_color(score, warn, _danger) when score >= warn, do: :yellow
  defp gauge_color(_score, _warn, _danger), do: :green
end
