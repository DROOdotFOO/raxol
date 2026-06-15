# Hot Code Reload Demo
#
# Demonstrates Raxol's hot code reload: edit view/1 while running
# and watch the UI update automatically.
#
# Usage:
#   iex -S mix run examples/dev/hot_reload_demo.exs
#
# Then edit the view/1 function below (e.g., change the title text)
# and save. The CodeReloader watches lib/ for .ex changes but also
# works with the module defined here when you recompile manually.

defmodule HotReloadDemo do
  use Raxol.Core.Runtime.Application

  @impl true
  def init(_context) do
    %{count: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      :increment ->
        {%{model | count: model.count + 1}, []}

      :decrement ->
        {%{model | count: model.count - 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "="}} ->
        {%{model | count: model.count + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "-"}} ->
        {%{model | count: model.count - 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    # Try editing this text while the app is running!
    column style: %{padding: 1, gap: 1, align_items: :center} do
      [
        text("Hot Reload Demo", style: [:bold]),
        text("Edit this view/1 function and save to see changes!"),
        box style: %{
              padding: 1,
              border: :single,
              width: 30,
              justify_content: :center
            } do
          text("Count: #{model.count}", style: [:bold])
        end,
        text("Press '='/'-' to change count, 'q' to quit")
      ]
    end
  end
end

{:ok, pid} = Raxol.start_link(HotReloadDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
