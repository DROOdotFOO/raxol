defmodule Raxol.UI.Components.Harness.SpendMeter do
  @moduledoc """
  Spend-vs-cap gauge: agent spend as a bar toward its session/lifetime cap,
  colored green -> yellow -> red as spend approaches the cap.

  Cost and control are the same concern -- this makes overspend visible
  before the bill, using the same three-tier gauge idiom as
  `Raxol.UI.Components.Harness.ContextMeter`.
  """

  alias Raxol.UI.Components.Progress.Bar
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type t :: %{
          id: String.t() | atom(),
          spent: number(),
          cap: number(),
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
          "spend-meter-#{:erlang.unique_integer([:positive])}"
        ),
      spent: Keyword.get(props, :spent, 0),
      cap: Keyword.get(props, :cap, 1),
      width: Keyword.get(props, :width, 20),
      warn_threshold: Keyword.get(props, :warn_threshold, 0.75),
      danger_threshold: Keyword.get(props, :danger_threshold, 0.9),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :spend_meter)

    safe_cap = max(state.cap * 1.0, 0.01)
    pct = min(state.spent / safe_cap, 1.0)
    color = gauge_color(pct, state.warn_threshold, state.danger_threshold)

    bar_string =
      Bar.bar(state.spent, max: safe_cap, width: state.width, style: :blocks)

    %{
      type: :row,
      style: base_style,
      gap: 1,
      children: [
        Raxol.View.Components.text(
          id: "#{state.id}-label",
          content: "Spend ",
          style: %{bold: true}
        ),
        Raxol.View.Components.text(
          id: "#{state.id}-bar",
          content: bar_string,
          fg: color
        ),
        Raxol.View.Components.text(
          id: "#{state.id}-amount",
          content: " #{format_money(state.spent)}/#{format_money(state.cap)}",
          style: %{dim: true}
        )
      ]
    }
  end

  defp gauge_color(pct, _warn, danger) when pct >= danger, do: :red
  defp gauge_color(pct, warn, _danger) when pct >= warn, do: :yellow
  defp gauge_color(_pct, _warn, _danger), do: :green

  defp format_money(amount) when is_number(amount) do
    "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)
  end
end
