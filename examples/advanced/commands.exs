# Commands
#
# Demonstrates async background commands and receiving results via update/2.
#
# Usage:
#   mix run examples/advanced/commands.exs

defmodule CommandsExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    %{results: [], next_id: 0, pending: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "t"}} ->
        id = model.next_id
        task = Directive.spawn(fn -> {id, do_work()} end)
        {%{model | next_id: id + 1, pending: model.pending + 1}, [task]}

      {:task_result, {id, result}} ->
        entry = "##{id}: #{result}"
        results = [entry | model.results] |> Enum.take(10)
        {%{model | results: results, pending: model.pending - 1}, []}

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
        text("Async Commands Demo", style: [:bold]),
        text(
          "Press 't' to start a background task | Pending: #{model.pending}"
        ),
        box title: "Results (last 10)", style: %{border: :single, padding: 1} do
          column do
            if model.results == [] do
              [text("No results yet...")]
            else
              Enum.map(model.results, fn r -> text(r) end)
            end
          end
        end,
        text("Press 'q' or Ctrl+C to quit.")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp do_work do
    Process.sleep(Enum.random(100..500))
    Enum.random(1..10_000)
  end
end

Raxol.Core.Runtime.Log.info("CommandsExample: Starting...")
{:ok, pid} = Raxol.start_link(CommandsExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
