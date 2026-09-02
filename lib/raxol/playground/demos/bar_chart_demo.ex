defmodule Raxol.Playground.Demos.BarChartDemo do
  @moduledoc "Playground demo: block-character bar chart with orientation toggle."
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @labels ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  @default_chart_width 50
  @chart_height 12
  @max_bar_value 100

  @impl true
  def init(_context) do
    %{
      orientation: :vertical,
      data: [45, 78, 32, 91, 56, 23, 67],
      show_values: true
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("o") ->
        new_orient =
          if model.orientation == :vertical, do: :horizontal, else: :vertical

        {%{model | orientation: new_orient}, []}

      key_match("v") ->
        {%{model | show_values: not model.show_values}, []}

      key_match("r") ->
        {%{
           model
           | data:
               Enum.map(1..length(@labels), fn _ ->
                 :rand.uniform(@max_bar_value)
               end)
         }, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    # snippet:start
    series = [%{name: "Weekly", data: model.data, color: :cyan}]

    chart_element =
      bar_chart(
        series: series,
        width: effective_width(model, @default_chart_width),
        height: @chart_height,
        orientation: model.orientation,
        show_values: model.show_values
      )

    # snippet:end

    values_label = if model.show_values, do: "ON", else: "OFF"

    labels_str =
      Enum.zip(@labels, model.data)
      |> Enum.map_join("  ", fn {l, v} -> "#{l}:#{v}" end)

    column style: %{gap: 1} do
      [
        text("BarChart Demo", style: [:bold]),
        divider(),
        chart_element,
        text("Orientation: #{model.orientation}  Values: #{values_label}"),
        text(labels_str, style: [:dim]),
        text("[o] orientation  [v] values  [r] randomize", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
