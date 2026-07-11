defmodule Raxol.Playground.Demos.SplitPaneDemo do
  @moduledoc """
  Playground demo: resizable split pane with direction toggle.

  Panes are sized with `style: %{width/height: {:pct, n}}` (`docs/core/LAYOUT.md`
  section 1) against an explicit, definite container width/height -- `{:pct, n}`
  only resolves against a *definite* dimension, so the row/column wrapping the
  panes is given one explicitly instead of relying on content measurement.
  Deliberately does NOT override the automatic minimum size (section 3) with
  `min_width: 0`/`min_height: 0`: at extreme ratios each pane still refuses to
  shrink below its own content floor, so the split degrades gracefully instead
  of squeezing text into an unreadable sliver.
  """
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @default_ratio 0.5
  @ratio_step 0.1
  @min_ratio 0.1
  @max_ratio 0.9
  @percent 100
  @default_total_width 60
  @stack_height 10

  @impl true
  def init(_context) do
    %{direction: :horizontal, ratio: @default_ratio, focus: :left}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("d") ->
        dir =
          if model.direction == :horizontal, do: :vertical, else: :horizontal

        {%{model | direction: dir}, []}

      key_match("h") ->
        {%{model | focus: :left}, []}

      key_match("l") ->
        {%{model | focus: :right}, []}

      key_match("=") ->
        {%{model | ratio: min(model.ratio + @ratio_step, @max_ratio)}, []}

      key_match("-") ->
        {%{model | ratio: max(model.ratio - @ratio_step, @min_ratio)}, []}

      key_match("r") ->
        {%{model | ratio: @default_ratio}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    left_indicator = if model.focus == :left, do: " [*]", else: ""
    right_indicator = if model.focus == :right, do: " [*]", else: ""
    left_style = if model.focus == :left, do: [:bold], else: []
    right_style = if model.focus == :right, do: [:bold], else: []
    pct = round(model.ratio * @percent)
    right_pct = @percent - pct

    size_key = if model.direction == :horizontal, do: :width, else: :height

    left_pane =
      box style: %{size_key => {:pct, pct}, border: :single, padding: 1} do
        column style: %{gap: 0} do
          [
            text("Left Pane#{left_indicator}", style: left_style),
            text("Ratio: #{pct}%")
          ]
        end
      end

    right_pane =
      box style: %{
            size_key => {:pct, right_pct},
            border: :single,
            padding: 1
          } do
        column style: %{gap: 0} do
          [
            text("Right Pane#{right_indicator}", style: right_style),
            text("Ratio: #{right_pct}%")
          ]
        end
      end

    panes =
      if model.direction == :horizontal do
        row style: %{
              gap: 1,
              width: effective_width(model, @default_total_width)
            } do
          [left_pane, right_pane]
        end
      else
        column style: %{gap: 1, height: @stack_height} do
          [left_pane, right_pane]
        end
      end

    column style: %{gap: 1} do
      [
        text("SplitPane Demo", style: [:bold]),
        divider(),
        panes,
        divider(),
        row style: %{gap: 2} do
          [
            text("Direction: #{model.direction}"),
            text("Ratio: #{pct}/#{@percent - pct}"),
            text("Focus: #{model.focus}")
          ]
        end,
        text("[d] direction  [h/l] focus  [=/-] resize  [r] reset",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
