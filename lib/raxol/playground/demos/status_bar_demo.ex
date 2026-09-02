defmodule Raxol.Playground.Demos.StatusBarDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Display.StatusBar` — the real
  component. The demo owns the editor-ish state (mode, position, uptime) and
  feeds it to the bar as items; the bar owns the rendering: bold keys,
  labels, separators.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Display.StatusBar

  @tick_interval_ms 1000
  @info_box_width 35

  @impl true
  def init(_context) do
    # snippet:start
    {:ok, bar} =
      StatusBar.init(
        id: :playground_status_bar,
        separator: " | ",
        items: [
          %{key: "MODE", label: "NORMAL"},
          %{key: "File", label: "demo.ex"},
          %{key: "Pos", label: "1:1"}
        ]
      )

    # Items are plain data: swap them on state changes, then draw with
    # StatusBar.render/2.
    # snippet:end
    %{bar: bar, mode: "NORMAL", file: "demo.ex", line: 1, col: 1, tick: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("i") ->
        {%{model | mode: "INSERT"}, []}

      key_match(:escape) ->
        {%{model | mode: "NORMAL"}, []}

      key_match("j") ->
        {%{model | line: model.line + 1}, []}

      key_match("k") ->
        {%{model | line: max(model.line - 1, 1)}, []}

      key_match("h") ->
        {%{model | col: max(model.col - 1, 1)}, []}

      key_match("l") ->
        {%{model | col: model.col + 1}, []}

      :tick ->
        {%{model | tick: model.tick + 1}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    bar = %{model.bar | items: items(model)}

    column style: %{gap: 1} do
      [
        text("StatusBar Demo", style: [:bold]),
        divider(),
        StatusBar.render(bar, %{}),
        divider(),
        box style: %{border: :single, padding: 1, width: @info_box_width} do
          column style: %{gap: 0} do
            [
              text("Mode: #{model.mode}"),
              text("File: #{model.file}"),
              text("Position: #{model.line}:#{model.col}"),
              text("Uptime: #{model.tick}s")
            ]
          end
        end,
        text("[i] insert  [Esc] normal  [hjkl] move", style: [:dim])
      ]
    end
  end

  defp items(model) do
    [
      %{key: "MODE", label: model.mode},
      %{key: "File", label: model.file},
      %{key: "Pos", label: "#{model.line}:#{model.col}"},
      %{key: "Up", label: "#{model.tick}s"}
    ]
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(@tick_interval_ms, :tick)]
  end
end
