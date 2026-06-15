# Split Pane Demo
#
# Demonstrates nested split panes with interactive resize.
#
# Layout:
#   +-- sidebar (1) --+-------- main area (2) ---------+
#   |                  |                                 |
#   |   Sidebar        |   Content Area          (3:1)  |
#   |   Panel          |                                |
#   |                  |   - Shows pane dimensions      |
#   |                  |   - Drag dividers to resize    |
#   |                  +--------------------------------+
#   |                  |   Status Bar                   |
#   +------------------+--------------------------------+
#
# Controls:
#   - Mouse drag on dividers to resize
#   - Ctrl+Left/Right to resize outer split
#   - Ctrl+Up/Down to resize inner split
#   - q or Ctrl+C to quit
#
# Usage:
#   mix run examples/apps/split_pane_demo.exs

defmodule SplitPaneDemo do
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Layout.SplitPane
  alias Raxol.UI.Layout.SplitPane.Resize

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    %{
      outer_ratio: {1, 2},
      inner_ratio: {3, 1},
      dragging: nil,
      width: 80,
      height: 24
    }
  end

  @impl true
  def update(message, model) do
    case message do
      # Quit
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      # Keyboard resize for outer split (horizontal)
      %Raxol.Core.Events.Event{type: :key, data: %{ctrl: true, key: key} = data}
      when key in [:arrow_left, :arrow_right] ->
        case Resize.handle_keyboard_resize(data, :horizontal, model.outer_ratio) do
          {:ok, new_ratio} -> {%{model | outer_ratio: new_ratio}, []}
          :ignore -> {model, []}
        end

      # Keyboard resize for inner split (vertical)
      %Raxol.Core.Events.Event{type: :key, data: %{ctrl: true, key: key} = data}
      when key in [:arrow_up, :arrow_down] ->
        case Resize.handle_keyboard_resize(data, :vertical, model.inner_ratio) do
          {:ok, new_ratio} -> {%{model | inner_ratio: new_ratio}, []}
          :ignore -> {model, []}
        end

      # Mouse press - check for divider hit
      %Raxol.Core.Events.Event{
        type: :mouse,
        data: %{action: :press, x: mx, y: my}
      } ->
        space = %{x: 0, y: 0, width: model.width, height: model.height}

        outer_dividers =
          Resize.divider_positions(:horizontal, model.outer_ratio, space)

        case Resize.check_divider_hit({mx, my}, outer_dividers, :horizontal) do
          {:hit, _idx} ->
            {%{model | dragging: {:outer, {mx, my}}}, []}

          :miss ->
            # Check inner dividers (in the right pane area)
            outer_sizes =
              SplitPane.distribute_space(
                :horizontal,
                Tuple.to_list(model.outer_ratio),
                space,
                5
              )

            left_width = hd(outer_sizes)

            inner_space = %{
              x: left_width + 1,
              y: 0,
              width: List.last(outer_sizes),
              height: model.height
            }

            inner_dividers =
              Resize.divider_positions(
                :vertical,
                model.inner_ratio,
                inner_space
              )

            case Resize.check_divider_hit({mx, my}, inner_dividers, :vertical) do
              {:hit, _idx} ->
                {%{model | dragging: {:inner, {mx, my}}}, []}

              :miss ->
                {model, []}
            end
        end

      # Mouse drag - resize if dragging
      %Raxol.Core.Events.Event{
        type: :mouse,
        data: %{action: :drag, x: mx, y: my}
      } ->
        case model.dragging do
          {:outer, _start} ->
            new_ratio =
              Resize.calculate_ratio(
                {mx, my},
                :horizontal,
                {0, 0},
                model.width,
                2
              )

            {%{model | outer_ratio: new_ratio}, []}

          {:inner, _start} ->
            outer_sizes =
              SplitPane.distribute_space(
                :horizontal,
                Tuple.to_list(model.outer_ratio),
                %{x: 0, y: 0, width: model.width, height: model.height},
                5
              )

            left_width = hd(outer_sizes)

            new_ratio =
              Resize.calculate_ratio(
                {mx, my},
                :vertical,
                {left_width + 1, 0},
                model.height,
                2
              )

            {%{model | inner_ratio: new_ratio}, []}

          nil ->
            {model, []}
        end

      # Mouse release - stop dragging
      %Raxol.Core.Events.Event{type: :mouse, data: %{action: :release}} ->
        {%{model | dragging: nil}, []}

      # Terminal resize
      %Raxol.Core.Events.Event{type: :resize, data: %{width: w, height: h}} ->
        {%{model | width: w, height: h}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    sidebar_content =
      column style: %{padding: 1} do
        [
          text("=== Sidebar ===", style: [:bold]),
          text(""),
          text("Outer: #{inspect(model.outer_ratio)}"),
          text("Inner: #{inspect(model.inner_ratio)}"),
          text(""),
          text("Drag dividers"),
          text("to resize."),
          text(""),
          text("Ctrl+Arrows"),
          text("also work."),
          text(""),
          text("q to quit")
        ]
      end

    main_content =
      column style: %{padding: 1} do
        [
          text("=== Content ===", style: [:bold]),
          text(""),
          text("Terminal: #{model.width}x#{model.height}"),
          text("Dragging: #{inspect(model.dragging)}"),
          text(""),
          text("This is the main content area."),
          text("It resizes when you drag the"),
          text("dividers or use Ctrl+arrows.")
        ]
      end

    status_content =
      column style: %{padding: 0} do
        [
          text("-- Status: Split Pane Demo | #{model.width}x#{model.height} --")
        ]
      end

    inner_split =
      SplitPane.new(
        direction: :vertical,
        ratio: model.inner_ratio,
        children: [main_content, status_content]
      )

    SplitPane.new(
      direction: :horizontal,
      ratio: model.outer_ratio,
      children: [sidebar_content, inner_split]
    )
  end

  @impl true
  def subscribe(_model) do
    []
  end
end

Raxol.Core.Runtime.Log.info("SplitPaneDemo: Starting...")
{:ok, pid} = Raxol.start_link(SplitPaneDemo, [])
Raxol.Core.Runtime.Log.info("SplitPaneDemo: Running. Press 'q' to quit.")

ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
