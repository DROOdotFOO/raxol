# Event Viewer
#
# Displays raw event data as it arrives, useful for debugging input handling.
#
# Usage:
#   mix run examples/scripts/event_viewer.exs

defmodule EventViewerExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @max_events 15

  @impl true
  def init(_context) do
    %{events: [], count: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{} = event ->
        entry = format_event(event, model.count + 1)
        events = [entry | model.events] |> Enum.take(@max_events)
        {%{model | events: events, count: model.count + 1}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Event Viewer", style: [:bold]),
        text("Events received: #{model.count}"),
        box title: "Recent Events (newest first)",
            style: %{border: :single, padding: 1} do
          column do
            if model.events == [] do
              [text("Waiting for events... (press any key)")]
            else
              Enum.map(model.events, fn entry -> text(entry) end)
            end
          end
        end,
        text("Press 'q' or Ctrl+C to quit.")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp format_event(%Raxol.Core.Events.Event{type: type, data: data}, n) do
    "##{n} #{type}: #{inspect(data, pretty: false, limit: 50)}"
  end
end

Raxol.Core.Runtime.Log.info("EventViewerExample: Starting...")
{:ok, pid} = Raxol.start_link(EventViewerExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
