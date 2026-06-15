defmodule Raxol.Demo.Todo do
  @moduledoc """
  Task list demo for `mix raxol.demo todo`.

  Demonstrates keyboard-driven TEA patterns with input modes,
  list navigation, and CRUD operations.

  Controls:
    Normal: j/k or arrows to navigate, Enter/Space to toggle, d to delete, a to add
    Input:  type text, Enter to submit, Backspace to delete, Escape to cancel
    q/Ctrl+C to quit
  """

  use Raxol.Core.Runtime.Application

  @impl true
  def init(_context) do
    %{
      todos: [
        %{id: 1, text: "Learn Raxol", done: false},
        %{id: 2, text: "Build a TUI app", done: false},
        %{id: 3, text: "Ship it", done: true}
      ],
      next_id: 4,
      cursor: 0,
      mode: :normal,
      input_buffer: ""
    }
  end

  @impl true
  def update(key_match("c", ctrl: true), model), do: {model, [Directive.stop()]}

  def update(message, %{mode: :input} = model), do: handle_input(message, model)
  def update(message, model), do: handle_normal(message, model)

  defp handle_normal(message, model), do: apply_normal_key(message, model)

  defp apply_normal_key(key_match("q"), model), do: {model, [Directive.stop()]}

  defp apply_normal_key(key_match(:down), model),
    do: {move_cursor(model, 1), []}

  defp apply_normal_key(key_match("j"), model), do: {move_cursor(model, 1), []}
  defp apply_normal_key(key_match(:up), model), do: {move_cursor(model, -1), []}
  defp apply_normal_key(key_match("k"), model), do: {move_cursor(model, -1), []}
  defp apply_normal_key(key_match(:enter), model), do: {toggle_done(model), []}
  defp apply_normal_key(key_match(:space), model), do: {toggle_done(model), []}
  defp apply_normal_key(key_match("d"), model), do: {delete_todo(model), []}

  defp apply_normal_key(key_match("a"), model),
    do: {%{model | mode: :input, input_buffer: ""}, []}

  defp apply_normal_key(_message, model), do: {model, []}

  defp handle_input(message, model) do
    case message do
      key_match(:enter) ->
        {submit_todo(model), []}

      key_match(:escape) ->
        {%{model | mode: :normal, input_buffer: ""}, []}

      key_match(:esc) ->
        {%{model | mode: :normal, input_buffer: ""}, []}

      key_match(:backspace) ->
        buf = String.slice(model.input_buffer, 0..-2//1)
        {%{model | input_buffer: buf}, []}

      key_match(:char, char: ch) when is_binary(ch) ->
        {%{model | input_buffer: model.input_buffer <> ch}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    done_count = Enum.count(model.todos, & &1.done)
    total = length(model.todos)

    column style: %{padding: 1, gap: 1} do
      [
        text("Todo List", style: [:bold]),
        todo_list_box(model),
        text("#{total} items, #{done_count} done"),
        help_text(model)
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- View helpers --

  defp todo_list_box(%{todos: []} = _model) do
    box style: %{padding: 1, border: :single, width: 40} do
      text("(no todos -- press 'a' to add one)")
    end
  end

  defp todo_list_box(model) do
    items =
      model.todos
      |> Enum.with_index()
      |> Enum.map(&render_todo_item(&1, model.cursor))

    box style: %{padding: 1, border: :single, width: 40} do
      column style: %{gap: 0} do
        items
      end
    end
  end

  defp render_todo_item({todo, idx}, cursor) do
    prefix = if idx == cursor, do: "> ", else: "  "
    check = if todo.done, do: "[x]", else: "[ ]"
    style = if idx == cursor, do: [:bold], else: []
    text("#{prefix}#{check} #{todo.text}", style: style)
  end

  defp help_text(%{mode: :input} = model) do
    text("New todo: #{model.input_buffer}_  [enter]submit [esc]cancel")
  end

  defp help_text(_model) do
    text("[a]dd  [d]elete  [enter]toggle  [j/k]move  [q]uit")
  end

  # -- Model helpers --

  defp move_cursor(model, delta) do
    len = length(model.todos)

    if len == 0 do
      model
    else
      new_cursor = Raxol.Core.Utils.Math.clamp(model.cursor + delta, 0, len - 1)
      %{model | cursor: new_cursor}
    end
  end

  defp toggle_done(%{todos: []} = model), do: model

  defp toggle_done(model) do
    todos =
      List.update_at(model.todos, model.cursor, fn todo ->
        %{todo | done: not todo.done}
      end)

    %{model | todos: todos}
  end

  defp delete_todo(%{todos: []} = model), do: model

  defp delete_todo(model) do
    todos = List.delete_at(model.todos, model.cursor)
    new_cursor = min(model.cursor, max(length(todos) - 1, 0))
    %{model | todos: todos, cursor: new_cursor}
  end

  defp submit_todo(model) do
    trimmed = String.trim(model.input_buffer)

    if trimmed == "" do
      %{model | mode: :normal, input_buffer: ""}
    else
      new_todo = %{id: model.next_id, text: trimmed, done: false}

      %{
        model
        | # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
          todos: model.todos ++ [new_todo],
          next_id: model.next_id + 1,
          cursor: length(model.todos),
          mode: :normal,
          input_buffer: ""
      }
    end
  end
end
