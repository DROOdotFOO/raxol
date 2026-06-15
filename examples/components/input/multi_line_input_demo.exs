# MultiLineInput Demo
#
# Demonstrates the multi-line text editor with undo/redo,
# cursor navigation, and word wrapping.
#
# Usage:
#   mix run examples/components/input/multi_line_input_demo.exs

defmodule MultiLineInputDemo do
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Input.MultiLineInput

  @initial_text """
  Welcome to the MultiLineInput demo!

  This widget supports:
  - Multi-line text editing
  - Word wrapping (try resizing)
  - Undo/Redo (Ctrl+Z / Ctrl+Y)
  - Cursor navigation (arrows, Home/End, PgUp/PgDn)
  - Selection (Shift+arrows)
  - Copy/Cut/Paste (Ctrl+C/X/V)

  Try editing this text!
  """

  @impl true
  def init(_context) do
    {:ok, editor_state} =
      MultiLineInput.init(%{
        id: :editor,
        value: String.trim(@initial_text),
        width: 55,
        height: 15,
        wrap: :word,
        placeholder: "Type here...",
        focused: true
      })

    %{editor: editor_state}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "q", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{} = event ->
        case MultiLineInput.handle_event(event, model.editor, %{theme: %{}}) do
          {:noreply, new_state, _cmds} ->
            {%{model | editor: new_state}, []}

          {new_state, cmds} when is_list(cmds) ->
            {%{model | editor: new_state}, []}

          _ ->
            {model, []}
        end

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    {row, col} = model.editor.cursor_pos
    line_count = length(model.editor.lines)
    undo_count = length(model.editor.history.undo)

    column style: %{padding: 1, gap: 1} do
      [
        text("MultiLineInput Demo", style: [:bold]),
        text("Type to edit. Ctrl+Z undo, Ctrl+Y redo. Ctrl+Q to quit."),
        box style: %{border: :single, width: 60} do
          MultiLineInput.render(model.editor, %{theme: %{}})
        end,
        row style: %{gap: 2} do
          [
            text("Ln #{row + 1}, Col #{col + 1}"),
            text("Lines: #{line_count}"),
            text("Undo: #{undo_count}")
          ]
        end
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end

{:ok, pid} = Raxol.start_link(MultiLineInputDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
