defmodule Raxol.Playground.Demos.StatusBarDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Display.StatusBar` — the REAL
  non-interactive status bar. Items are `%{key: string, label: string}`
  pairs joined by a configurable separator; keys render bold.

  Display.StatusBar has no keyboard handlers (`handle_event/3` is a
  passthrough). This demo keeps editor-ish fields in the model (mode,
  file, cursor, uptime tick) and rebuilds the bar's `items` on every
  change so the mounted component reflects live state.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Display.StatusBar

  @tick_interval_ms 1000

  @impl true
  def init(_context) do
    fields = %{
      mode: "NORMAL",
      file: "demo.ex",
      line: 1,
      col: 1,
      tick: 0
    }

    %{
      fields: fields,
      status_bar: build_bar(fields),
      event_log: []
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("i") ->
        apply_fields(model, %{mode: "INSERT"}, "mode -> INSERT")

      key_match(:escape) ->
        apply_fields(model, %{mode: "NORMAL"}, "mode -> NORMAL")

      key_match("v") ->
        apply_fields(model, %{mode: "VISUAL"}, "mode -> VISUAL")

      key_match("j") ->
        line = model.fields.line + 1
        apply_fields(model, %{line: line}, "line -> #{line}")

      key_match("k") ->
        line = max(model.fields.line - 1, 1)
        apply_fields(model, %{line: line}, "line -> #{line}")

      key_match("h") ->
        col = max(model.fields.col - 1, 1)
        apply_fields(model, %{col: col}, "col -> #{col}")

      key_match("l") ->
        col = model.fields.col + 1
        apply_fields(model, %{col: col}, "col -> #{col}")

      key_match("f") ->
        file =
          if model.fields.file == "demo.ex", do: "table.ex", else: "demo.ex"

        apply_fields(model, %{file: file}, "file -> #{file}")

      :tick ->
        tick = model.fields.tick + 1
        # Quiet ticks: update items without flooding the event log every second.
        fields = Map.put(model.fields, :tick, tick)
        {%{model | fields: fields, status_bar: build_bar(fields)}, []}

      _ ->
        {model, []}
    end
  end

  defp apply_fields(model, patch, summary) do
    fields = Map.merge(model.fields, patch)
    model = DemoHelpers.log_event(model, summary)

    {%{model | fields: fields, status_bar: build_bar(fields)}, []}
  end

  defp build_bar(fields) do
    {:ok, bar} =
      StatusBar.init(
        id: :playground_status_bar,
        separator: " │ ",
        items: [
          %{key: "Mode", label: fields.mode},
          %{key: "File", label: fields.file},
          %{key: "Pos", label: "#{fields.line}:#{fields.col}"},
          %{key: "Up", label: "#{fields.tick}s"}
        ]
      )

    bar
  end

  @impl true
  def view(model) do
    f = model.fields

    # A second story with a denser separator / different items so the
    # catalog shows that StatusBar is a generic key/label layout, not
    # an editor chrome widget.
    {:ok, alt} =
      StatusBar.init(
        id: :playground_status_alt,
        separator: " · ",
        items: [
          %{key: "branch", label: "main"},
          %{key: "ahead", label: "2"},
          %{key: "dirty", label: if(f.mode == "INSERT", do: "yes", else: "no")}
        ]
      )

    column style: %{gap: 1} do
      [
        text("StatusBar — Raxol.UI.Components.Display.StatusBar",
          style: [:bold]
        ),
        text(
          " non-interactive key/label items; demo rebuilds items on key/tick",
          style: [:dim]
        ),
        text(""),
        text(" live editor-ish bar:", style: [:dim]),
        box style: %{border: :single, padding: 0, width: 56} do
          StatusBar.render(model.status_bar, %{})
        end,
        text(""),
        text(" alternate separator / items:", style: [:dim]),
        box style: %{border: :single, padding: 0, width: 56} do
          StatusBar.render(alt, %{})
        end,
        text(""),
        row style: %{gap: 2} do
          [
            text("Mode: #{f.mode}"),
            text("File: #{f.file}"),
            text("Pos: #{f.line}:#{f.col}"),
            text("Up: #{f.tick}s")
          ]
        end,
        text(
          " [i] INSERT  [Esc] NORMAL  [v] VISUAL  [hjkl] move  [f] toggle file",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(@tick_interval_ms, :tick)]
  end
end
