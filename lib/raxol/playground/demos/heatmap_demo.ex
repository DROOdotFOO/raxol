defmodule Raxol.Playground.Demos.HeatmapDemo do
  @moduledoc "Playground demo: 2D heatmap with color scale cycling."
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @grid_rows 8
  @grid_cols 12
  @default_chart_width 48
  @chart_height 16
  @scales [:warm, :cool, :diverging]

  @impl true
  def init(_context) do
    # Seeded, so every boot opens on the same grid and the recorded preview
    # is reproducible. [r] keeps drawing from the stream, so randomize still
    # randomizes; only the opening frame is pinned.
    :rand.seed(:exsss, {42, 7, 19})
    %{grid: random_grid(), color_scale: :warm}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("s") ->
        {%{model | color_scale: next_scale(model.color_scale)}, []}

      key_match("r") ->
        {%{model | grid: random_grid()}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    rows = length(model.grid)

    cols =
      case model.grid do
        [first_row | _] -> length(first_row)
        [] -> 0
      end

    chart_element =
      heatmap(
        data: model.grid,
        width: effective_width(model, @default_chart_width),
        height: @chart_height,
        color_scale: model.color_scale
      )

    column style: %{gap: 1} do
      [
        text("Heatmap Demo", style: [:bold]),
        divider(),
        chart_element,
        text("Scale: #{model.color_scale}  Grid: #{rows}x#{cols}"),
        text("[s] cycle scale  [r] randomize", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp random_grid do
    for _r <- 1..@grid_rows, do: for(_c <- 1..@grid_cols, do: :rand.uniform())
  end

  defp next_scale(current) do
    idx = Enum.find_index(@scales, &(&1 == current))
    Enum.at(@scales, DemoHelpers.cycle_next(idx, length(@scales)))
  end
end
