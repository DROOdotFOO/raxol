# Progress Bar Test
#
# Demonstrates a cycling progress bar using TEA subscriptions.
#
# Usage:
#   mix run examples/components/displays/progress_bar_test.exs

defmodule ProgressBarTestExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @bar_width 40

  @impl true
  def init(_context) do
    %{progress: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        new_val = if model.progress >= 100, do: 0, else: model.progress + 5
        {%{model | progress: new_val}, []}

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
    filled = trunc(model.progress / 100 * @bar_width)
    empty = @bar_width - filled
    bar = String.duplicate("█", filled) <> String.duplicate("░", empty)

    column style: %{padding: 1, gap: 1} do
      [
        text("Progress Bar Example", style: [:bold]),
        text("Value: #{model.progress}%"),
        text("[#{bar}]"),
        text("Press 'q' or Ctrl+C to quit.")
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(500, :tick)]
  end
end

Raxol.Core.Runtime.Log.info("ProgressBarTestExample: Starting...")
{:ok, pid} = Raxol.start_link(ProgressBarTestExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
