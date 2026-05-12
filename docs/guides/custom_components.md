# Custom Components

Raxol provides two levels for building reusable UI:

1. **View helpers** -- Private functions in your TEA app that return element trees. Start here.
2. **Component behaviour** -- `Raxol.UI.Components.Base.Component` for stateful, reusable widgets with lifecycle hooks.

Most apps only need view helpers. Use the component behaviour when you need internal state, event handling, or want to publish a reusable widget.

---

## View Helpers (Recommended Start)

Extract parts of your `view/1` into private functions. These are plain Elixir -- no special framework support needed.

```elixir
defmodule MyApp do
  use Raxol.Core.Runtime.Application

  @impl true
  def init(_context), do: %{items: ["Milk", "Eggs", "Bread"], cursor: 0}

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "j"}} ->
        {%{model | cursor: min(model.cursor + 1, length(model.items) - 1)}, []}
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "k"}} ->
        {%{model | cursor: max(model.cursor - 1, 0)}, []}
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [command(:quit)]}
      _ -> {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        header("Shopping List"),
        item_list(model.items, model.cursor),
        footer()
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- View helpers --
  # These are just functions returning element trees.
  # No special behaviour, no lifecycle -- plain Elixir.

  defp header(title) do
    box style: %{border: :double, width: :fill, padding: 0} do
      text(title, style: [:bold], fg: :cyan)
    end
  end

  defp item_list(items, cursor) do
    rows =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        prefix = if idx == cursor, do: "> ", else: "  "
        style = if idx == cursor, do: [:bold], else: []
        text("#{prefix}#{item}", style: style)
      end)

    box style: %{border: :single, padding: 1, width: 30} do
      column style: %{gap: 0} do
        rows
      end
    end
  end

  defp footer do
    text("[j/k] navigate  [q] quit", style: [:dim])
  end
end
```

View helpers are composable, testable (call them and inspect the return value), and require zero boilerplate. Use them for panels, status bars, formatted tables, help text -- anything that's a pure function of data.

---

## Component Behaviour

For widgets that need their own state and event handling, use the component behaviour. Built-in widgets like `Button`, `TextInput`, `Checkbox`, `Table`, `SelectList`, and `Modal` all use this pattern.

### The Behaviour

`Raxol.UI.Components.Base.Component` defines these callbacks:

| Callback | Required? | Purpose |
|----------|-----------|---------|
| `init/1` | Yes | Initialize state from props. Return `{:ok, state}` or just `state`. |
| `render/2` | Yes | Render state to an element tree. `render(state, context)` |
| `handle_event/3` | Yes | Handle UI events. `handle_event(event, state, context)` |
| `update/2` | Yes | Handle messages. `update(message, state)` |
| `mount/1` | No | Setup after init (subscriptions, etc). Default: `{state, []}` |
| `unmount/1` | No | Cleanup on removal. Default: `state` |

### Minimal Example

```elixir
defmodule MyApp.Components.Counter do
  use Raxol.UI.Components.Base.Component

  @impl true
  def init(props) do
    {:ok, %{
      id: Map.get(props, :id, "counter"),
      count: Map.get(props, :initial, 0),
      on_change: Map.get(props, :on_change),
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{})
    }}
  end

  @impl true
  def update(:increment, state) do
    new_state = %{state | count: state.count + 1}
    notify(new_state)
    new_state
  end

  def update(:decrement, state) do
    new_state = %{state | count: state.count - 1}
    notify(new_state)
    new_state
  end

  def update(_msg, state), do: state

  @impl true
  def render(state, _context) do
    row style: %{gap: 1} do
      [
        button("-", on_click: {:click, :decrement}),
        text("#{state.count}", style: [:bold]),
        button("+", on_click: {:click, :increment})
      ]
    end
  end

  @impl true
  def handle_event({:click, action}, state, _context) do
    {update(action, state), []}
  end

  def handle_event(_event, state, _context) do
    {state, []}
  end

  defp notify(%{on_change: nil}), do: :ok
  defp notify(%{on_change: callback, count: count}), do: callback.(count)
end
```

### Using a Component

Components are used via their module's `init/1`, `handle_event/3`, and `render/2`:

```elixir
# In your TEA app's init/1:
{:ok, counter_state} = MyApp.Components.Counter.init(%{initial: 10})
model = %{counter: counter_state}

# In update/2, forward events:
counter = MyApp.Components.Counter.update(:increment, model.counter)
{%{model | counter: counter}, []}

# In view/1:
MyApp.Components.Counter.render(model.counter, %{})
```

### Real-World Pattern: Checkbox

Here's how the built-in Checkbox is structured (simplified):

```elixir
defmodule Raxol.UI.Components.Input.Checkbox do
  use Raxol.UI.Components.Base.Component

  @impl true
  def init(props) do
    {:ok, %{
      id: Keyword.get(props, :id, "checkbox-#{:erlang.unique_integer([:positive])}"),
      checked: Keyword.get(props, :checked, false),
      disabled: Keyword.get(props, :disabled, false),
      label: Keyword.get(props, :label, ""),
      on_toggle: Keyword.get(props, :on_toggle),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{}),
      focused: false
    }}
  end

  @impl true
  def handle_event(%Event{type: :key, data: %{key: :space}}, state, _ctx) do
    if state.disabled do
      {state, []}
    else
      new_state = %{state | checked: not state.checked}
      if state.on_toggle, do: state.on_toggle.(new_state.checked)
      {new_state, []}
    end
  end

  def handle_event(_event, state, _ctx), do: {state, []}

  @impl true
  def render(state, _context) do
    mark = if state.checked, do: "[x]", else: "[ ]"
    style = if state.focused, do: [:bold], else: []
    text("#{mark} #{state.label}", style: style)
  end

  # update/2 handles prop changes
  @impl true
  def update(props, state) when is_map(props) do
    Raxol.UI.Components.Base.Component.merge_props(props, state)
  end

  def update(_msg, state), do: state
end
```

Key patterns:
- `init/1` takes a keyword list or map, returns `{:ok, state}`
- State is a flat map with `:id`, `:style`, `:theme` (standard keys)
- `handle_event/3` pattern-matches on `%Event{}` structs
- Disabled state is checked before acting
- Callbacks (`:on_toggle`) are optional and nil-checked
- `merge_props/2` handles style/theme deep-merging when props update

---

## Guidelines

### State Shape

All components should include these standard keys:

```elixir
%{
  id: "unique-id",       # Required for the rendering pipeline
  style: %{},            # Layout/visual overrides
  theme: %{},            # Theme tokens
  focused: false,        # Focus state (for keyboard navigation)
  disabled: false         # Disabled state (skip event handling)
}
```

Add component-specific keys alongside these.

### Event Handling

Events arrive as `%Raxol.Core.Events.Event{}` structs:

```elixir
def handle_event(%Event{type: :key, data: %{key: :enter}}, state, _ctx) do
  # Handle enter key
  {state, []}
end

def handle_event(%Event{type: :key, data: %{key: :char, char: ch}}, state, _ctx) do
  # Handle printable character
  {%{state | buffer: state.buffer <> ch}, []}
end
```

Return `{new_state, commands}` or `:passthrough` to let the event bubble up.

### Testing

Components are plain modules -- test them directly:

```elixir
test "checkbox toggles on space" do
  {:ok, state} = Checkbox.init(checked: false, label: "Agree")

  space = %Raxol.Core.Events.Event{type: :key, data: %{key: :space}}
  {new_state, []} = Checkbox.handle_event(space, state, %{})

  assert new_state.checked == true
end

test "disabled checkbox ignores events" do
  {:ok, state} = Checkbox.init(checked: false, disabled: true)

  space = %Raxol.Core.Events.Event{type: :key, data: %{key: :space}}
  {new_state, []} = Checkbox.handle_event(space, state, %{})

  assert new_state.checked == false
end
```

### When to Use What

| Need | Approach |
|------|----------|
| Panel, section, formatted output | View helper (private function) |
| Reusable widget with internal state | Component behaviour |
| One-off stateful widget in your app | Keep state in your TEA model |
| Crash-isolated widget | `process_component(MyWidget, props)` |

Start with view helpers. Graduate to the component behaviour when you find yourself passing state and event handlers around manually.

---

## Further Reading

- [Widget Gallery](../getting-started/WIDGET_GALLERY.md) -- All built-in widgets with examples
- [Building Apps](../cookbook/BUILDING_APPS.md) -- TEA patterns and recipes
- [Examples](../../examples/README.md) -- Runnable examples from beginner to advanced
- Built-in components to study: `lib/raxol/ui/components/input/` and `lib/raxol/ui/components/display/`
