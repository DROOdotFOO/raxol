defmodule Raxol.Playground.Demos.ProgressDemo do
  @moduledoc "Playground demo: progress bar with value tracking."
  use Raxol.Core.Runtime.Application

  @bar_width 30
  @max_progress 100
  @manual_step 5
  @auto_step 2
  @auto_tick_ms 200
  @info_box_width 35
  @label_pad_width 8

  @impl true
  def init(_context) do
    %{value: 50, auto: false}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("=") ->
        {%{model | value: min(model.value + @manual_step, @max_progress)}, []}

      key_match("-") ->
        {%{model | value: max(model.value - @manual_step, 0)}, []}

      key_match("a") ->
        {%{model | auto: not model.auto}, []}

      key_match("r") ->
        {%{model | value: 0}, []}

      :tick when model.auto ->
        new_val =
          if model.value >= @max_progress, do: 0, else: model.value + @auto_step

        {%{model | value: new_val}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    filled = round(model.value / @max_progress * @bar_width)
    empty = @bar_width - filled
    bar = String.duplicate("#", filled) <> String.duplicate(".", empty)
    auto_label = if model.auto, do: "ON", else: "OFF"

    column style: %{gap: 1} do
      [
        text("Progress Demo", style: [:bold]),
        divider(),
        # snippet:start
        progress(value: model.value, max: @max_progress),
        # snippet:end
        text("[#{bar}] #{model.value}%"),
        divider(),
        box style: %{border: :single, padding: 1, width: @info_box_width} do
          column style: %{gap: 0} do
            [
              text("Value: #{model.value}/#{@max_progress}"),
              text("Auto-increment: #{auto_label}")
            ]
          end
        end,
        visual_bars(model.value),
        text("[=/-] adjust  [a] auto  [r] reset", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(model) do
    if model.auto do
      [subscribe_interval(@auto_tick_ms, :tick)]
    else
      []
    end
  end

  defp visual_bars(value) do
    column style: %{gap: 0} do
      [
        bar_line("Default", value, @bar_width),
        bar_line("Half", div(value, 2), @bar_width),
        bar_line("Double", min(value * 2, @max_progress), @bar_width)
      ]
    end
  end

  defp bar_line(label, val, width) do
    filled = round(val / @max_progress * width)
    empty = width - filled
    bar = String.duplicate("=", filled) <> String.duplicate("-", empty)
    text("#{String.pad_trailing(label, @label_pad_width)} [#{bar}] #{val}%")
  end
end
