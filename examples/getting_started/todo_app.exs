# Todo List Example
#
# A keyboard-driven todo list with two modes: normal and input.
#
# What you'll learn:
#   - State machine pattern: model.mode gates which keys are active
#   - Guard clauses on pattern matches (when model.mode == :normal)
#   - View decomposition: extracting helpers to keep view/1 readable
#   - Model helpers: pure functions for state transitions
#
# Usage:
#   mix run examples/getting_started/todo_app.exs
#
# Controls:
#   Normal mode:  j/Down = cursor down, k/Up = cursor up
#                 Enter/Space = toggle done, d = delete, a = add
#                 q/Ctrl+C = quit
#   Input mode:   type to enter text, Enter = submit,
#                 Backspace = delete char, Escape = cancel

defmodule TodoExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    %{
      todos: [
        %{id: 1, text: "Learn Raxol", done: false},
        %{id: 2, text: "Build a TUI app", done: false},
        %{id: 3, text: "Read AGENTS.md", done: true}
      ],
      next_id: 4,
      cursor: 0,
      mode: :normal,
      input_buffer: ""
    }
  end

  @impl true
  def update(message, model) do
    case message do
      # Guards on model.mode create a state machine: the same physical key
      # does different things depending on the current mode. "q" quits in
      # :normal mode but types the letter "q" in :input mode (caught by
      # the printable character clause below).

      # -- Quit --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}}
      when model.mode == :normal ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      # -- Normal mode: navigation --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "j"}}
      when model.mode == :normal ->
        {move_cursor(model, 1), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :down}}
      when model.mode == :normal ->
        {move_cursor(model, 1), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "k"}}
      when model.mode == :normal ->
        {move_cursor(model, -1), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :up}}
      when model.mode == :normal ->
        {move_cursor(model, -1), []}

      # -- Normal mode: toggle done --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}}
      when model.mode == :normal ->
        {toggle_done(model), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :space}}
      when model.mode == :normal ->
        {toggle_done(model), []}

      # -- Normal mode: delete --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "d"}}
      when model.mode == :normal ->
        {delete_todo(model), []}

      # -- Normal mode: enter input mode --
      # Mode transition: switch from :normal to :input.
      # This changes which key handlers are active on the next update.
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "a"}}
      when model.mode == :normal ->
        {%{model | mode: :input, input_buffer: ""}, []}

      # -- Input mode: submit --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}}
      when model.mode == :input ->
        {submit_todo(model), []}

      # -- Input mode: cancel --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :esc}}
      when model.mode == :input ->
        {%{model | mode: :normal, input_buffer: ""}, []}

      # -- Input mode: backspace --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :backspace}}
      when model.mode == :input ->
        buf = String.slice(model.input_buffer, 0..-2//1)
        {%{model | input_buffer: buf}, []}

      # -- Input mode: printable character --
      # `is_binary(ch)` guard filters to actual text characters.
      # Special keys like :enter/:esc have atom values, not binaries.
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: ch}}
      when model.mode == :input and is_binary(ch) ->
        {%{model | input_buffer: model.input_buffer <> ch}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    done_count = Enum.count(model.todos, & &1.done)
    total = length(model.todos)

    # View decomposition: todo_list_box/1 and help_text/1 are private
    # helper functions that return element trees. This keeps view/1
    # readable even as the UI grows complex.
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
  def subscribe(_model) do
    []
  end

  # -- View helpers --

  defp todo_list_box(model) do
    if model.todos == [] do
      box style: %{padding: 1, border: :single, width: 40} do
        text("(no todos -- press 'a' to add one)")
      end
    else
      items =
        model.todos
        |> Enum.with_index()
        |> Enum.map(fn {todo, idx} ->
          prefix = if idx == model.cursor, do: "> ", else: "  "
          check = if todo.done, do: "[x]", else: "[ ]"
          style = if idx == model.cursor, do: [:bold], else: []
          text("#{prefix}#{check} #{todo.text}", style: style)
        end)

      box style: %{padding: 1, border: :single, width: 40} do
        column style: %{gap: 0} do
          items
        end
      end
    end
  end

  defp help_text(model) do
    case model.mode do
      :normal ->
        text("[a]dd  [d]elete  [enter]toggle  [q]uit")

      :input ->
        cursor =
          if rem(System.os_time(:millisecond), 1000) < 500, do: "_", else: " "

        text(
          "New todo: #{model.input_buffer}#{cursor}  [enter]submit [esc]cancel"
        )
    end
  end

  # -- Model helpers --
  # Pure functions extracted from update/2. Each takes the model and
  # returns a new model. No side effects, easy to test in isolation.

  defp move_cursor(model, delta) do
    len = length(model.todos)

    if len == 0 do
      model
    else
      new_cursor = model.cursor + delta
      new_cursor = max(0, min(new_cursor, len - 1))
      %{model | cursor: new_cursor}
    end
  end

  defp toggle_done(model) do
    if model.todos == [] do
      model
    else
      todos =
        List.update_at(model.todos, model.cursor, fn todo ->
          %{todo | done: not todo.done}
        end)

      %{model | todos: todos}
    end
  end

  defp delete_todo(model) do
    if model.todos == [] do
      model
    else
      todos = List.delete_at(model.todos, model.cursor)
      new_cursor = min(model.cursor, max(length(todos) - 1, 0))
      %{model | todos: todos, cursor: new_cursor}
    end
  end

  defp submit_todo(model) do
    trimmed = String.trim(model.input_buffer)

    if trimmed == "" do
      %{model | mode: :normal, input_buffer: ""}
    else
      new_todo = %{id: model.next_id, text: trimmed, done: false}

      %{
        model
        | todos: model.todos ++ [new_todo],
          next_id: model.next_id + 1,
          cursor: length(model.todos),
          mode: :normal,
          input_buffer: ""
      }
    end
  end
end

Raxol.Core.Runtime.Log.info("TodoExample: Starting Raxol...")
{:ok, pid} = Raxol.start_link(TodoExample, [])
Raxol.Core.Runtime.Log.info("TodoExample: Raxol started. Running...")

# Keep the script alive until the application process exits
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
