defmodule Raxol.Playground.Demos.TextAreaDemo do
  @moduledoc "Playground demo: multi-line text editor with insert and normal modes."
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @default_editor_width 50
  @line_number_pad 2

  @impl true
  def init(_context) do
    %{
      lines: ["Hello, world!", "Edit me with 'i'", ""],
      cursor_line: 0,
      cursor_col: 0,
      mode: :normal
    }
  end

  @impl true
  def update(message, %{mode: :normal} = model),
    do: handle_normal_mode(message, model)

  def update(message, %{mode: :insert} = model),
    do: handle_insert_mode(message, model)

  def update(_message, model), do: {model, []}

  defp handle_normal_mode(message, model) do
    case message do
      key_match("i") ->
        {%{
           model
           | mode: :insert,
             cursor_col: String.length(current_line(model))
         }, []}

      key_match("j") ->
        max_line = length(model.lines) - 1

        {%{
           model
           | cursor_line: DemoHelpers.cursor_down(model.cursor_line, max_line)
         }, []}

      key_match("k") ->
        {%{model | cursor_line: DemoHelpers.cursor_up(model.cursor_line)}, []}

      _ ->
        {model, []}
    end
  end

  defp handle_insert_mode(message, model) do
    case message do
      key_match(:escape) ->
        {%{model | mode: :normal}, []}

      key_match(:enter) ->
        insert_newline(model)

      key_match(:backspace) ->
        delete_backward(model)

      key_match(:char, char: ch) when byte_size(ch) == 1 ->
        insert_char(model, ch)

      _ ->
        {model, []}
    end
  end

  defp insert_newline(model) do
    lines = List.insert_at(model.lines, model.cursor_line + 1, "")

    {%{model | lines: lines, cursor_line: model.cursor_line + 1, cursor_col: 0},
     []}
  end

  defp delete_backward(model) do
    new_line = String.slice(current_line(model), 0..-2//1)
    lines = List.replace_at(model.lines, model.cursor_line, new_line)

    {%{
       model
       | lines: lines,
         cursor_col: DemoHelpers.cursor_up(model.cursor_col)
     }, []}
  end

  defp insert_char(model, ch) do
    line = current_line(model) <> ch
    lines = List.replace_at(model.lines, model.cursor_line, line)
    {%{model | lines: lines, cursor_col: model.cursor_col + 1}, []}
  end

  defp current_line(model), do: Enum.at(model.lines, model.cursor_line, "")

  @impl true
  def view(model) do
    mode_str = if model.mode == :normal, do: "NORMAL", else: "INSERT"

    line_rows =
      model.lines
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        prefix = if i == model.cursor_line, do: ">", else: " "
        num = String.pad_leading("#{i + 1}", @line_number_pad)
        text("#{prefix} #{num} | #{line}")
      end)

    column style: %{gap: 1} do
      [
        text("TextArea Demo", style: [:bold]),
        text("Mode: #{mode_str}", style: [:bold]),
        divider(),
        box style: %{
              border: :single,
              padding: 1,
              width: effective_width(model, @default_editor_width)
            } do
          column(style: %{gap: 0}, do: line_rows)
        end,
        text("Ln #{model.cursor_line + 1}, Col #{model.cursor_col}"),
        text("[i] insert  [esc] normal  [j/k] navigate  [enter] newline",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
