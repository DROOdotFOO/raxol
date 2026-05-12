# Building Apps

You've built a counter. Now let's look at patterns you'll reach for in real apps.

> All code below assumes `use Raxol.Core.Runtime.Application`, which aliases
> `Raxol.Core.Events.Event` as `Event`. You can write `%Event{...}` instead of
> the full module path.

## State Design

### Flat state with derived values

Keep your model flat. Derive display values in `view/1`, not `update/2`:

```elixir
# Model -- just raw data
%{
  items: ["milk", "eggs", "bread"],
  cursor: 0,
  filter: "",
  editing: false
}

# Derive in view
def view(model) do
  filtered = Enum.filter(model.items, &String.contains?(&1, model.filter))
  visible_count = length(filtered)
  # ...render filtered, visible_count...
end
```

### State machines via pattern matching

Use atoms for mode, pattern match in both `update/2` and `view/1`:

```elixir
def init(_ctx), do: %{mode: :browsing, items: [], selected: nil}

def update(msg, %{mode: :browsing} = model) do
  case msg do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}} ->
      {%{model | mode: :editing}, []}
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "/"}} ->
      {%{model | mode: :searching, filter: ""}, []}
    _ -> {model, []}
  end
end

def update(msg, %{mode: :searching} = model) do
  case msg do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :escape}} ->
      {%{model | mode: :browsing, filter: ""}, []}
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: c}} ->
      {%{model | filter: model.filter <> c}, []}
    _ -> {model, []}
  end
end

def view(%{mode: :browsing} = model), do: render_browser(model)
def view(%{mode: :searching} = model), do: render_search(model)
def view(%{mode: :editing} = model), do: render_editor(model)
```

## Common Recipes

These patterns solve real problems. Use **state machines** when your app has distinct modes (browsing vs editing vs searching). Use **scrollable lists** when you have more items than fit on screen. Use **keychord sequences** for Vim-style multi-key commands.

### Scrollable list

```elixir
def init(_ctx) do
  %{
    items: Enum.map(1..100, &"Item #{&1}"),
    cursor: 0,
    scroll_offset: 0,
    visible_rows: 20
  }
end

def update(msg, model) do
  case msg do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :down}} ->
      new_cursor = min(model.cursor + 1, length(model.items) - 1)
      scroll = adjust_scroll(new_cursor, model.scroll_offset, model.visible_rows)
      {%{model | cursor: new_cursor, scroll_offset: scroll}, []}

    %Raxol.Core.Events.Event{type: :key, data: %{key: :up}} ->
      new_cursor = max(model.cursor - 1, 0)
      scroll = adjust_scroll(new_cursor, model.scroll_offset, model.visible_rows)
      {%{model | cursor: new_cursor, scroll_offset: scroll}, []}

    _ -> {model, []}
  end
end

defp adjust_scroll(cursor, offset, visible) do
  cond do
    cursor < offset -> cursor
    cursor >= offset + visible -> cursor - visible + 1
    true -> offset
  end
end

def view(model) do
  visible_items =
    model.items
    |> Enum.slice(model.scroll_offset, model.visible_rows)
    |> Enum.with_index(model.scroll_offset)

  column do
    Enum.map(visible_items, fn {item, idx} ->
      if idx == model.cursor do
        text("> #{item}", fg: :cyan, style: [:bold])
      else
        text("  #{item}")
      end
    end)
  end
end
```

See `examples/getting_started/todo_app.exs` for a working scrollable list.

### Periodic data refresh

```elixir
def subscribe(_model) do
  [subscribe_interval(1000, :refresh)]
end

def update(:refresh, model) do
  stats = %{
    memory: :erlang.memory(:total) |> div(1024 * 1024),
    processes: :erlang.system_info(:process_count),
    uptime: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
  }
  {%{model | stats: stats}, []}
end
```

### Confirmation dialog

```elixir
def update(:delete_pressed, model) do
  {%{model | confirm: "Delete #{model.selected}?"}, []}
end

def update(:confirm_yes, model) do
  items = List.delete(model.items, model.selected)
  {%{model | items: items, confirm: nil, selected: nil}, []}
end

def update(:confirm_no, model) do
  {%{model | confirm: nil}, []}
end

def view(%{confirm: msg} = model) when is_binary(msg) do
  column do
    [
      render_main(model),
      box style: %{border: :double, padding: 1, width: 40} do
        column style: %{gap: 1} do
          [
            text(msg, fg: :yellow, style: [:bold]),
            row style: %{gap: 2} do
              [
                button("Yes", on_click: :confirm_yes),
                button("No", on_click: :confirm_no)
              ]
            end
          ]
        end
      end
    ]
  end
end
```

### Multi-panel layout with Tab switching

```elixir
@panels [:files, :preview, :log]

def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :tab}}, model) do
  current = Enum.find_index(@panels, &(&1 == model.panel))
  next = Enum.at(@panels, rem(current + 1, length(@panels)))
  {%{model | panel: next}, []}
end

def view(model) do
  column do
    [
      # Tab bar
      row style: %{height: 1} do
        Enum.map(@panels, fn panel ->
          if panel == model.panel do
            text(" #{panel} ", fg: :black, bg: :cyan, style: [:bold])
          else
            text(" #{panel} ", fg: :white)
          end
        end)
      end,
      # Active panel content
      box style: %{border: :single, flex: 1} do
        render_panel(model.panel, model)
      end
    ]
  end
end
```

### Sparkline helper

Render inline charts from a list of values:

```elixir
@spark_chars ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

defp sparkline(values) when values == [], do: ""

defp sparkline(values) do
  max_val = Enum.max(values)
  if max_val == 0 do
    String.duplicate(hd(@spark_chars), length(values))
  else
    values
    |> Enum.map(fn v ->
      idx = trunc(v / max_val * 7)
      Enum.at(@spark_chars, min(idx, 7))
    end)
    |> Enum.join()
  end
end

# Usage in view:
text("Memory: #{sparkline(model.memory_history)}", fg: :green)
```

See `examples/demo.exs` for sparklines in action.

### Progress bar helper

```elixir
defp progress_bar(value, max, width) do
  pct = if max > 0, do: value / max, else: 0
  filled = trunc(pct * width)
  empty = width - filled
  String.duplicate("█", filled) <> String.duplicate("░", empty)
end

# Usage:
text("[#{progress_bar(75, 100, 30)}] 75%", fg: :cyan)
```

## Keyboard Patterns

### Vim-style keybindings

```elixir
def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "j"}}, model) do
  # Down
  {%{model | cursor: min(model.cursor + 1, length(model.items) - 1)}, []}
end

def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "k"}}, model) do
  # Up
  {%{model | cursor: max(model.cursor - 1, 0)}, []}
end

def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "g", ctrl: false}}, model) do
  # Go to top
  {%{model | cursor: 0}, []}
end

def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "G"}}, model) do
  # Go to bottom
  {%{model | cursor: length(model.items) - 1}, []}
end
```

### Key chord sequences

Track a key buffer for multi-key commands:

```elixir
def update(%Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: c}}, model) do
  chord = model.key_buffer <> c

  case chord do
    "dd" -> {%{model | items: delete_current(model), key_buffer: ""}, []}
    "gg" -> {%{model | cursor: 0, key_buffer: ""}, []}
    _ when byte_size(chord) >= 2 -> {%{model | key_buffer: ""}, []}
    _ -> {%{model | key_buffer: chord}, []}
  end
end
```

## Styling Patterns

### Color by value

```elixir
defp status_color(:ok), do: :green
defp status_color(:warning), do: :yellow
defp status_color(:error), do: :red
defp status_color(_), do: :white

defp cpu_color(pct) when pct > 90, do: :red
defp cpu_color(pct) when pct > 70, do: :yellow
defp cpu_color(_), do: :green
```

### Bordered panels with titles

```elixir
defp panel(title, content, opts \\ []) do
  fg = Keyword.get(opts, :fg, :cyan)

  box style: %{border: :single, flex: 1, padding: 0} do
    column do
      [
        text(" #{title} ", fg: fg, style: [:bold]),
        text(String.duplicate("─", 40), fg: :magenta),
        content
      ]
    end
  end
end
```

### Conditional content

```elixir
def view(model) do
  column do
    [
      text("Status: #{model.status}"),
      if model.loading do
        text("Loading...", fg: :yellow)
      else
        text("Ready", fg: :green)
      end,
      if model.error do
        text("Error: #{model.error}", fg: :red)
      end
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
```

## Testing

### Test your update function

`update/2` is a pure function -- test it directly:

```elixir
test "increment increases count" do
  model = %{count: 0}
  {new_model, cmds} = MyApp.update(:increment, model)
  assert new_model.count == 1
  assert cmds == []
end

test "quit sends command" do
  model = %{count: 0}
  quit_event = %Raxol.Core.Events.Event{
    type: :key, data: %{key: :char, char: "q"}
  }
  {_model, cmds} = MyApp.update(quit_event, model)
  assert [{:quit, _}] = cmds
end
```

### Test state transitions

```elixir
test "search mode filters items" do
  key = fn
    k when is_atom(k) -> %Raxol.Core.Events.Event{type: :key, data: %{key: k, char: nil}}
    c -> %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: c}}
  end

  model = %{mode: :browsing, items: ["apple", "banana", "avocado"], filter: ""}

  # Enter search mode
  {model, _} = MyApp.update(key.("/"), model)
  assert model.mode == :searching

  # Type filter
  {model, _} = MyApp.update(key.("a"), model)
  assert model.filter == "a"

  # Escape returns to browsing
  {model, _} = MyApp.update(key.(:escape), model)
  assert model.mode == :browsing
  assert model.filter == ""
end
```

## Next Steps

- [SSH Deployment](./SSH_DEPLOYMENT.md) -- Serve apps over SSH
- [Theming](./THEMING.md) -- Custom color schemes
- [Performance](./PERFORMANCE_OPTIMIZATION.md) -- 60fps techniques
- [Component Gallery](../getting-started/COMPONENT_GALLERY.md) -- All Components with examples
