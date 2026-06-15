# Simple Editor
#
# A single-line text editor demonstrating character input and deletion.
#
# Usage:
#   mix run examples/advanced/editor.exs

defmodule EditorExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    %{text: "", cursor: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :backspace}} ->
        if model.cursor > 0 do
          {before, after_cursor} = String.split_at(model.text, model.cursor)
          new_text = String.slice(before, 0..-2//1) <> after_cursor
          {%{model | text: new_text, cursor: model.cursor - 1}, []}
        else
          {model, []}
        end

      %Raxol.Core.Events.Event{type: :key, data: %{key: :delete}} ->
        {before, after_cursor} = String.split_at(model.text, model.cursor)

        new_after =
          if after_cursor == "",
            do: "",
            else: String.slice(after_cursor, 1..-1//1)

        {%{model | text: before <> new_after}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_left}} ->
        {%{model | cursor: max(0, model.cursor - 1)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_right}} ->
        {%{model | cursor: min(String.length(model.text), model.cursor + 1)},
         []}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: ch}}
      when is_binary(ch) ->
        if String.printable?(ch) do
          {before, after_cursor} = String.split_at(model.text, model.cursor)
          new_text = before <> ch <> after_cursor
          {%{model | text: new_text, cursor: model.cursor + 1}, []}
        else
          {model, []}
        end

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    {before, after_cursor} = String.split_at(model.text, model.cursor)
    display = before <> "_" <> after_cursor

    column style: %{padding: 1, gap: 1} do
      [
        box title: "Simple Editor (Ctrl+C to quit)",
            style: %{border: :single, padding: 1} do
          text(display)
        end,
        text("#{String.length(model.text)} chars | cursor: #{model.cursor}")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end

Raxol.Core.Runtime.Log.info("EditorExample: Starting...")
{:ok, pid} = Raxol.start_link(EditorExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
