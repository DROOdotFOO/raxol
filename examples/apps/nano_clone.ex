defmodule Examples.Editor.NanoClone do
  @moduledoc """
  A nano-like text editor built with Raxol TEA pattern.

  Features:
  - File loading and saving
  - Cursor movement
  - Insert/delete characters
  - Status bar with file info

  Run with: mix run examples/apps/nano_clone.ex [filename]
  """

  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    filename = List.first(System.argv())

    content =
      if filename && File.exists?(filename) do
        File.read!(filename) |> String.split("\n")
      else
        [""]
      end

    %{
      filename: filename,
      lines: content,
      row: 0,
      col: 0,
      scroll: 0,
      modified: false,
      status: "^X Exit | ^O Save | ^W Search"
    }
  end

  @impl true
  def update(message, model) do
    case message do
      # Save
      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "o", ctrl: true}
      } ->
        {save_file(model), []}

      # Quit
      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "x", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      # Navigation
      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_up}} ->
        {move(model, :up), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_down}} ->
        {move(model, :down), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_left}} ->
        {move(model, :left), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_right}} ->
        {move(model, :right), []}

      # Editing
      %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}} ->
        {insert_newline(model), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :backspace}} ->
        {delete_backward(model), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: ch}}
      when is_binary(ch) ->
        if String.printable?(ch) do
          {insert_char(model, ch), []}
        else
          {model, []}
        end

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    title =
      (model.filename || "New File") <>
        if(model.modified, do: " *", else: "") <>
        " | Ln #{model.row + 1}, Col #{model.col + 1}"

    visible_lines = Enum.slice(model.lines, model.scroll, 20)

    column do
      [
        box title: title, style: %{border: :single, padding: 0} do
          column do
            visible_lines
            |> Enum.with_index(model.scroll)
            |> Enum.map(fn {line, idx} ->
              num = String.pad_leading("#{idx + 1}", 4)

              cursor_marker =
                if idx == model.row do
                  {before, after_c} = String.split_at(line, model.col)
                  "#{num} #{before}_#{after_c}"
                else
                  "#{num} #{line}"
                end

              text(cursor_marker)
            end)
          end
        end,
        text(" #{model.status}")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- Movement --

  defp move(model, :up) do
    new_row = max(0, model.row - 1)
    line = Enum.at(model.lines, new_row, "")

    %{model | row: new_row, col: min(model.col, String.length(line))}
    |> adjust_scroll()
  end

  defp move(model, :down) do
    new_row = min(length(model.lines) - 1, model.row + 1)
    line = Enum.at(model.lines, new_row, "")

    %{model | row: new_row, col: min(model.col, String.length(line))}
    |> adjust_scroll()
  end

  defp move(model, :left) do
    %{model | col: max(0, model.col - 1)}
  end

  defp move(model, :right) do
    line = Enum.at(model.lines, model.row, "")
    %{model | col: min(String.length(line), model.col + 1)}
  end

  # -- Editing --

  defp insert_char(model, ch) do
    line = Enum.at(model.lines, model.row, "")
    {before, after_c} = String.split_at(line, model.col)
    new_line = before <> ch <> after_c
    lines = List.replace_at(model.lines, model.row, new_line)
    %{model | lines: lines, col: model.col + 1, modified: true}
  end

  defp insert_newline(model) do
    line = Enum.at(model.lines, model.row, "")
    {before, after_c} = String.split_at(line, model.col)

    lines =
      model.lines
      |> List.replace_at(model.row, before)
      |> List.insert_at(model.row + 1, after_c)

    %{model | lines: lines, row: model.row + 1, col: 0, modified: true}
    |> adjust_scroll()
  end

  defp delete_backward(model) do
    cond do
      model.col > 0 ->
        line = Enum.at(model.lines, model.row, "")
        {before, after_c} = String.split_at(line, model.col)
        new_line = String.slice(before, 0..-2//1) <> after_c
        lines = List.replace_at(model.lines, model.row, new_line)
        %{model | lines: lines, col: model.col - 1, modified: true}

      model.row > 0 ->
        prev = Enum.at(model.lines, model.row - 1, "")
        curr = Enum.at(model.lines, model.row, "")

        lines =
          model.lines
          |> List.replace_at(model.row - 1, prev <> curr)
          |> List.delete_at(model.row)

        %{
          model
          | lines: lines,
            row: model.row - 1,
            col: String.length(prev),
            modified: true
        }
        |> adjust_scroll()

      true ->
        model
    end
  end

  # -- Helpers --

  defp adjust_scroll(model) do
    cond do
      model.row < model.scroll -> %{model | scroll: model.row}
      model.row >= model.scroll + 20 -> %{model | scroll: model.row - 19}
      true -> model
    end
  end

  defp save_file(%{filename: nil} = model) do
    %{model | status: "No filename! Use: mix run nano_clone.ex <file>"}
  end

  defp save_file(model) do
    content = Enum.join(model.lines, "\n")

    case File.write(model.filename, content) do
      :ok ->
        %{
          model
          | modified: false,
            status: "Saved #{model.filename} (#{byte_size(content)} bytes)"
        }

      {:error, reason} ->
        %{model | status: "Error: #{inspect(reason)}"}
    end
  end
end

# Start the editor
Raxol.Core.Runtime.Log.info("NanoClone: Starting...")
{:ok, pid} = Raxol.start_link(Examples.Editor.NanoClone, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
