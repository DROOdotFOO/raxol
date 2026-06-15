# Advanced Todo App Example
#
# A fully-featured todo list demonstrating TEA patterns with
# persistence, search, filtering, and keyboard shortcuts.
#
# Usage:
#   mix run examples/apps/todo_app.ex
#
# Controls:
#   Normal mode:  j/Down = down, k/Up = up, Enter/Space = toggle
#                 a = add, e = edit, d = delete, s = save to disk
#                 / = search, 1/2/3 = filter (all/active/done)
#                 q/Ctrl+C = quit
#   Input mode:   type text, Enter = submit, Escape = cancel

defmodule TodoApp do
  use Raxol.Core.Runtime.Application

  @storage_file Path.expand("~/.raxol_todos.json")

  @impl true
  def init(_context) do
    todos = load_todos()

    %{
      todos: todos,
      next_id: next_id(todos),
      cursor: 0,
      mode: :normal,
      input_buffer: "",
      editing_id: nil,
      filter: :all,
      search: "",
      message: nil
    }
  end

  @impl true
  def update(message, model) do
    case message do
      # -- Quit --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}}
      when model.mode == :normal ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      # -- Normal mode --
      %Raxol.Core.Events.Event{type: :key, data: data}
      when model.mode == :normal ->
        {handle_normal_key(data, model), []}

      # -- Input/Search mode --
      %Raxol.Core.Events.Event{type: :key, data: data}
      when model.mode in [:input, :edit, :search] ->
        {handle_input_key(data, model), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    filtered = filtered_todos(model)
    done_count = Enum.count(model.todos, & &1.done)
    total = length(model.todos)

    column style: %{padding: 1, gap: 1} do
      [
        row style: %{gap: 2} do
          [
            text("Todo List", style: [:bold]),
            text("#{done_count}/#{total} done", style: %{fg: :cyan})
          ]
        end,
        filter_bar(model),
        search_bar(model),
        todo_list(model, filtered),
        input_area(model),
        status_bar(model)
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- Normal mode key handling --

  defp handle_normal_key(%{key: :char, char: "j"}, m), do: move_cursor(m, 1)
  defp handle_normal_key(%{key: :down}, m), do: move_cursor(m, 1)
  defp handle_normal_key(%{key: :char, char: "k"}, m), do: move_cursor(m, -1)
  defp handle_normal_key(%{key: :up}, m), do: move_cursor(m, -1)
  defp handle_normal_key(%{key: :enter}, m), do: toggle_done(m)
  defp handle_normal_key(%{key: :space}, m), do: toggle_done(m)

  defp handle_normal_key(%{key: :char, char: "a"}, m),
    do: %{m | mode: :input, input_buffer: "", message: nil}

  defp handle_normal_key(%{key: :char, char: "e"}, m), do: start_edit(m)
  defp handle_normal_key(%{key: :char, char: "d"}, m), do: delete_todo(m)

  defp handle_normal_key(%{key: :char, char: "s"}, m) do
    save_todos(m.todos)
    %{m | message: "Saved #{length(m.todos)} todos to disk"}
  end

  defp handle_normal_key(%{key: :char, char: "/"}, m),
    do: %{m | mode: :search, input_buffer: m.search, message: nil}

  defp handle_normal_key(%{key: :char, char: "1"}, m),
    do: %{m | filter: :all, cursor: 0}

  defp handle_normal_key(%{key: :char, char: "2"}, m),
    do: %{m | filter: :active, cursor: 0}

  defp handle_normal_key(%{key: :char, char: "3"}, m),
    do: %{m | filter: :done, cursor: 0}

  defp handle_normal_key(_, m), do: m

  # -- Input mode key handling --

  defp handle_input_key(%{key: :enter}, %{mode: :input} = m), do: submit_todo(m)
  defp handle_input_key(%{key: :enter}, %{mode: :edit} = m), do: save_edit(m)

  defp handle_input_key(%{key: :enter}, %{mode: :search} = m),
    do: %{m | mode: :normal, search: m.input_buffer, cursor: 0}

  defp handle_input_key(%{key: :esc}, m),
    do: %{m | mode: :normal, input_buffer: "", editing_id: nil}

  defp handle_input_key(%{key: :backspace}, m),
    do: %{m | input_buffer: String.slice(m.input_buffer, 0..-2//1)}

  defp handle_input_key(%{key: :char, char: ch}, m) when is_binary(ch),
    do: %{m | input_buffer: m.input_buffer <> ch}

  defp handle_input_key(_, m), do: m

  # -- View helpers --

  defp filter_bar(model) do
    labels = [
      {:all, "1:All"},
      {:active, "2:Active"},
      {:done, "3:Done"}
    ]

    items =
      Enum.map(labels, fn {filter, label} ->
        style = if model.filter == filter, do: [:bold], else: %{fg: :white}
        text(label, style: style)
      end)

    row style: %{gap: 2} do
      items
    end
  end

  defp search_bar(%{search: ""}), do: text("")

  defp search_bar(%{search: search}),
    do: text("Search: #{search}", style: %{fg: :yellow})

  defp todo_list(model, filtered) do
    if filtered == [] do
      box style: %{padding: 1, border: :single, width: 50} do
        text(empty_message(model), style: %{fg: :white})
      end
    else
      items =
        filtered
        |> Enum.with_index()
        |> Enum.map(fn {todo, idx} ->
          prefix = if idx == model.cursor, do: "> ", else: "  "
          check = if todo.done, do: "[x]", else: "[ ]"
          style = if idx == model.cursor, do: [:bold], else: []
          text("#{prefix}#{check} #{todo.text}", style: style)
        end)

      box style: %{padding: 1, border: :single, width: 50} do
        column style: %{gap: 0} do
          items
        end
      end
    end
  end

  defp input_area(%{mode: :input, input_buffer: buf}),
    do: text("New: #{buf}_  [enter]submit [esc]cancel", style: %{fg: :green})

  defp input_area(%{mode: :edit, input_buffer: buf}),
    do: text("Edit: #{buf}_  [enter]save [esc]cancel", style: %{fg: :yellow})

  defp input_area(%{mode: :search, input_buffer: buf}),
    do: text("Search: #{buf}_  [enter]apply [esc]cancel", style: %{fg: :cyan})

  defp input_area(_), do: text("")

  defp status_bar(%{message: msg}) when is_binary(msg) do
    text(msg, style: %{fg: :green})
  end

  defp status_bar(_) do
    text("[a]dd [e]dit [d]el [s]ave [/]search [1-3]filter [q]uit")
  end

  defp empty_message(%{search: s}) when s != "", do: "No todos match '#{s}'"
  defp empty_message(%{filter: :active}), do: "No active todos"
  defp empty_message(%{filter: :done}), do: "No completed todos"
  defp empty_message(_), do: "No todos -- press 'a' to add one"

  # -- Model helpers --

  defp filtered_todos(model) do
    model.todos
    |> filter_by_status(model.filter)
    |> filter_by_search(model.search)
  end

  defp filter_by_status(todos, :all), do: todos
  defp filter_by_status(todos, :active), do: Enum.reject(todos, & &1.done)
  defp filter_by_status(todos, :done), do: Enum.filter(todos, & &1.done)

  defp filter_by_search(todos, ""), do: todos

  defp filter_by_search(todos, search) do
    term = String.downcase(search)

    Enum.filter(todos, fn t ->
      String.contains?(String.downcase(t.text), term)
    end)
  end

  defp move_cursor(model, delta) do
    filtered = filtered_todos(model)
    len = length(filtered)

    if len == 0 do
      model
    else
      new_cursor = Raxol.Core.Utils.Math.clamp(model.cursor + delta, 0, len - 1)
      %{model | cursor: new_cursor}
    end
  end

  defp toggle_done(model) do
    case todo_at_cursor(model) do
      nil ->
        model

      todo ->
        todos =
          Enum.map(model.todos, fn t ->
            if t.id == todo.id, do: %{t | done: not t.done}, else: t
          end)

        %{model | todos: todos}
    end
  end

  defp delete_todo(model) do
    case todo_at_cursor(model) do
      nil ->
        model

      todo ->
        todos = Enum.reject(model.todos, &(&1.id == todo.id))

        filtered_len =
          length(
            filter_by_status(todos, model.filter)
            |> filter_by_search(model.search)
          )

        new_cursor = min(model.cursor, max(filtered_len - 1, 0))
        %{model | todos: todos, cursor: new_cursor}
    end
  end

  defp start_edit(model) do
    case todo_at_cursor(model) do
      nil ->
        model

      todo ->
        %{model | mode: :edit, editing_id: todo.id, input_buffer: todo.text}
    end
  end

  defp save_edit(model) do
    trimmed = String.trim(model.input_buffer)

    if trimmed == "" do
      %{model | mode: :normal, editing_id: nil, input_buffer: ""}
    else
      todos =
        Enum.map(model.todos, fn t ->
          if t.id == model.editing_id, do: %{t | text: trimmed}, else: t
        end)

      %{model | todos: todos, mode: :normal, editing_id: nil, input_buffer: ""}
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
          mode: :normal,
          input_buffer: ""
      }
    end
  end

  defp todo_at_cursor(model) do
    filtered_todos(model) |> Enum.at(model.cursor)
  end

  # -- Persistence --

  defp save_todos(todos) do
    data =
      Enum.map(todos, fn t ->
        %{"id" => t.id, "text" => t.text, "done" => t.done}
      end)

    File.write!(@storage_file, Jason.encode!(data, pretty: true))
  rescue
    _ -> :ok
  end

  defp load_todos do
    if File.exists?(@storage_file) do
      @storage_file
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn item ->
        %{
          id: item["id"],
          text: item["text"],
          done: item["done"] || false
        }
      end)
    else
      [
        %{id: 1, text: "Learn Raxol", done: false},
        %{id: 2, text: "Build a TUI app", done: false},
        %{id: 3, text: "Read AGENTS.md", done: true}
      ]
    end
  rescue
    _ ->
      [%{id: 1, text: "Welcome to TodoApp", done: false}]
  end

  defp next_id([]), do: 1

  defp next_id(todos) do
    todos |> Enum.map(& &1.id) |> Enum.max() |> Kernel.+(1)
  end
end

{:ok, pid} = Raxol.start_link(TodoApp, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
