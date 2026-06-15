# Viewport Demo
#
# Demonstrates the scrollable Viewport widget with keyboard navigation.
#
# Usage:
#   mix run examples/components/displays/viewport_demo.exs

defmodule ViewportDemo do
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Display.Viewport

  @line_count 50

  @impl true
  def init(_context) do
    lines =
      Enum.map(1..@line_count, fn i ->
        Raxol.View.Components.text(
          content: "Line #{i}: #{String.duplicate("~", rem(i, 30) + 5)}"
        )
      end)

    {:ok, vp_state} =
      Viewport.init(
        id: :main_viewport,
        children: lines,
        visible_height: 15,
        show_scrollbar: true,
        focused: true
      )

    %{viewport: vp_state}
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

      %Raxol.Core.Events.Event{type: :key} = event ->
        {new_vp, _cmds} = Viewport.handle_event(event, model.viewport, %{})
        {%{model | viewport: new_vp}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    vp = model.viewport

    pos =
      "#{vp.scroll_top + 1}-#{min(vp.scroll_top + vp.visible_height, vp.content_height)}/#{vp.content_height}"

    column style: %{padding: 1, gap: 1} do
      [
        text("Viewport Demo", style: [:bold]),
        text("Use Up/Down, PgUp/PgDn, Home/End to scroll. Press 'q' to quit."),
        box style: %{border: :single, width: 60} do
          Viewport.render(model.viewport, %{})
        end,
        text("Position: #{pos}")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end

{:ok, pid} = Raxol.start_link(ViewportDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
