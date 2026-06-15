defmodule Raxol.Examples.ProgressBarDemo do
  @moduledoc """
  A demo application showcasing text-based progress bars with different styles.
  """

  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @bar_width 30

  @impl true
  def init(_context) do
    %{
      basic: 0,
      block: 0,
      custom: 0,
      running: true
    }
  end

  @impl true
  def update(message, model) do
    case message do
      :tick when model.running ->
        new = %{
          model
          | basic: min(model.basic + 5, 100),
            block: min(model.block + 3, 100),
            custom: min(model.custom + 7, 100)
        }

        running = new.basic < 100 or new.block < 100 or new.custom < 100
        {%{new | running: running}, []}

      :restart ->
        {%{model | basic: 0, block: 0, custom: 0, running: true}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "r"}} ->
        {%{model | basic: 0, block: 0, custom: 0, running: true}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Progress Bar Demo", style: [:bold]),
        box title: "Progress", style: %{border: :single, padding: 1} do
          column style: %{gap: 1} do
            [
              render_bar("Basic ", model.basic, "=", "-"),
              render_bar("Block ", model.block, "█", "░"),
              render_bar("Custom", model.custom, "▣", "□"),
              text(""),
              if model.running do
                text("Running...")
              else
                text("Done! Press 'r' to restart.")
              end
            ]
          end
        end,
        text("Press 'r' to restart | 'q' to quit")
      ]
    end
  end

  @impl true
  def subscribe(%{running: true}) do
    [subscribe_interval(100, :tick)]
  end

  def subscribe(_model), do: []

  defp render_bar(label, pct, filled_ch, empty_ch) do
    filled = trunc(pct / 100 * @bar_width)
    empty = @bar_width - filled

    bar =
      String.duplicate(filled_ch, filled) <> String.duplicate(empty_ch, empty)

    text("#{label} [#{bar}] #{pct}%")
  end
end
