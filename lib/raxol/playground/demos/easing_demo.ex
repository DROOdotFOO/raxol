defmodule Raxol.Playground.Demos.EasingDemo do
  @moduledoc "Playground demo: animated easing function showcase."
  use Raxol.Core.Runtime.Application

  alias Raxol.Animation.Easing

  @easings [
    :linear,
    :ease_in_quad,
    :ease_out_quad,
    :ease_in_out_cubic,
    :ease_in_elastic,
    :ease_out_bounce,
    :ease_in_out_back,
    :ease_in_expo
  ]

  @plot_width 30
  @plot_height 10
  @cycle_ticks 40
  @tick_interval_ms 50

  @impl true
  def init(_context) do
    %{
      easing_index: 0,
      progress: 0.0,
      tick: 0
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match(:up) ->
        {select_easing(model, -1), []}

      key_match(:down) ->
        {select_easing(model, 1), []}

      key_match(:left) ->
        {select_easing(model, -1), []}

      key_match(:right) ->
        {select_easing(model, 1), []}

      key_match("r") ->
        {%{model | progress: 0.0, tick: 0}, []}

      :tick ->
        {advance_tick(model), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    # snippet:start
    easing = current_easing(model)
    label = easing |> to_string() |> String.replace("_", " ")
    eased = Easing.calculate_value(easing, model.progress)
    marker_x = round(model.progress * @plot_width)
    marker_y = round(eased * @plot_height)

    # snippet:end

    column style: %{gap: 0} do
      [
        text("Easing Demo", style: [:bold]),
        text("Function: #{label}", fg: :cyan),
        text(
          "Progress: #{Float.round(model.progress, 2)}  Value: #{Float.round(eased, 2)}",
          style: [:dim]
        ),
        text(""),
        render_plot(easing, marker_x, marker_y),
        render_marker_bar(marker_x),
        text(""),
        easing_list(model.easing_index),
        text("[arrows] change  [r] reset", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(@tick_interval_ms, :tick)]
  end

  defp select_easing(model, delta) do
    max_idx = length(@easings) - 1
    idx = Raxol.Core.Utils.Math.clamp(model.easing_index + delta, 0, max_idx)
    %{model | easing_index: idx, progress: 0.0, tick: 0}
  end

  defp advance_tick(model) do
    new_tick = model.tick + 1
    progress = rem(new_tick, @cycle_ticks) / @cycle_ticks
    %{model | tick: new_tick, progress: progress}
  end

  defp current_easing(model) do
    Enum.at(@easings, model.easing_index)
  end

  defp render_plot(easing, marker_x, _marker_y) do
    lines =
      for row <- @plot_height..0//-1 do
        for col <- 0..@plot_width do
          plot_char(easing, col, row, marker_x)
        end
        |> Enum.join()
      end

    column style: %{gap: 0} do
      Enum.map(lines, fn line -> text(line, fg: :green) end)
    end
  end

  defp plot_char(easing, col, row, marker_x) do
    val = Easing.calculate_value(easing, col / @plot_width)
    plot_y = Float.round(val * @plot_height, 0) |> trunc()

    cond do
      col == marker_x and plot_y == row -> "@"
      plot_y == row and within_range?(val) -> "*"
      row == 0 -> "-"
      col == 0 -> "|"
      true -> " "
    end
  end

  defp render_marker_bar(marker_x) do
    bar =
      for x <- 0..@plot_width do
        if x == marker_x, do: "^", else: "-"
      end

    text(Enum.join(bar), fg: :yellow)
  end

  defp within_range?(val), do: val >= 0.0 and val <= 1.0

  defp easing_list(active_idx) do
    items =
      @easings
      |> Enum.with_index()
      |> Enum.map(fn {easing, idx} ->
        label = easing |> to_string() |> String.replace("_", " ")

        if idx == active_idx do
          text(" > #{label}", style: [:bold], fg: :cyan)
        else
          text("   #{label}", style: [:dim])
        end
      end)

    column style: %{gap: 0} do
      items
    end
  end
end
