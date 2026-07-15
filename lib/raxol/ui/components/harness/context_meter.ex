defmodule Raxol.UI.Components.Harness.ContextMeter do
  @moduledoc """
  Compaction-proximity gauge: how much of the context window is used.

  Renders a `Raxol.UI.Components.Progress.Bar` bar colored green -> yellow ->
  red as `used` approaches `total` (the compaction threshold). Mirrors the
  three-tier gauge idiom already used by `Raxol.Sensor.HUD.render_gauge/3`
  (percentage thresholds, not hardcoded token counts), kept local here since
  that module renders raw terminal cells rather than View DSL elements.
  """

  alias Raxol.UI.Components.Progress.Bar
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type t :: %{
          id: String.t() | atom(),
          used: non_neg_integer(),
          total: pos_integer(),
          width: pos_integer(),
          warn_threshold: float(),
          danger_threshold: float(),
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
          "context-meter-#{:erlang.unique_integer([:positive])}"
        ),
      used: Keyword.get(props, :used, 0),
      total: Keyword.get(props, :total, 1),
      width: Keyword.get(props, :width, 20),
      warn_threshold: Keyword.get(props, :warn_threshold, 0.75),
      danger_threshold: Keyword.get(props, :danger_threshold, 0.9),
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
      StyleHelper.merge_component_styles(state, context, :context_meter)

    safe_total = max(state.total, 1)
    pct = min(state.used / safe_total, 1.0)
    color = gauge_color(pct, state.warn_threshold, state.danger_threshold)

    bar_string =
      Bar.bar(state.used, max: safe_total, width: state.width, style: :blocks)

    %{
      type: :row,
      style: base_style,
      children: [
        Raxol.View.Components.text(
          id: "#{state.id}-label",
          content: "Context ",
          style: %{bold: true}
        ),
        Raxol.View.Components.text(
          id: "#{state.id}-bar",
          content: bar_string,
          fg: color
        ),
        Raxol.View.Components.text(
          id: "#{state.id}-count",
          content: " #{state.used}/#{state.total}",
          style: %{dim: true}
        )
      ]
    }
  end

  defp gauge_color(pct, _warn, danger) when pct >= danger, do: :red
  defp gauge_color(pct, warn, _danger) when pct >= warn, do: :yellow
  defp gauge_color(_pct, _warn, _danger), do: :green
end
