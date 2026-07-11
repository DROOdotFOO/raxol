# LiveView Integration

Two approaches: the **TEA bridge** (`Raxol.LiveView.TEALive`) runs a full TEA app rendered to HTML via PubSub, and the **raw Buffer** approach where you build a `Buffer` and push it to the LiveView yourself. Most recipes below use the raw approach since it's simpler to show in isolation.

> **Note:** Direct buffer manipulation via `Raxol.Core.{Buffer, Box}` is an advanced, low-level approach. The canonical Raxol API is TEA-based: your `view/1` callback returns an element tree and the framework handles rendering. Prefer the TEA bridge for new integrations.

## Basic Terminal Embedding

### Static Terminal

```elixir
defmodule MyAppWeb.SimpleTerminalLive do
  use MyAppWeb, :live_view
  alias Raxol.Core.{Buffer, Box}

  def mount(_params, _session, socket) do
    buffer =
      Buffer.create_blank_buffer(80, 24)
      |> Box.draw_box(0, 0, 80, 24, :double)
      |> Buffer.write_at(10, 10, "Welcome to My App!", %{bold: true, fg_color: :cyan})
      |> Buffer.write_at(10, 12, "Press any key to continue...")

    {:ok, assign(socket, buffer: buffer)}
  end

  def render(assigns) do
    ~H"""
    <div class="container">
      <.live_component
        module={Raxol.LiveView.TerminalComponent}
        id="terminal"
        buffer={@buffer}
        theme={:nord}
      />
    </div>
    """
  end
end
```

### Periodic Updates

```elixir
defmodule MyAppWeb.ClockLive do
  use MyAppWeb, :live_view
  alias Raxol.Core.{Buffer, Box}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :tick)
    end

    {:ok, assign(socket, buffer: create_clock())}
  end

  def handle_info(:tick, socket) do
    {:noreply, assign(socket, buffer: create_clock())}
  end

  defp create_clock do
    time = Time.utc_now() |> Time.to_string() |> String.slice(0..7)

    Buffer.create_blank_buffer(30, 10)
    |> Box.draw_box(0, 0, 30, 10, :single)
    |> Buffer.write_at(10, 4, time, %{fg_color: :green, bold: true})
  end
end
```

---

## Event Handling

### Keyboard Input

```elixir
def render(assigns) do
  ~H"""
  <.live_component
    module={Raxol.LiveView.TerminalComponent}
    id="keyboard"
    buffer={@buffer}
    theme={:nord}
    on_keypress="handle_keypress"
  />
  """
end

def handle_event("handle_keypress", %{"key" => key}, socket) do
  socket =
    socket
    |> update(:key_count, &(&1 + 1))
    |> assign(last_key: key)
    |> update_buffer()

  {:noreply, socket}
end
```

### Mouse Clicks

```elixir
def render(assigns) do
  ~H"""
  <.live_component
    module={Raxol.LiveView.TerminalComponent}
    id="mouse"
    buffer={@buffer}
    theme={:dracula}
    on_click="handle_click"
  />
  """
end

def handle_event("handle_click", %{"x" => x, "y" => y}, socket) do
  buffer = Buffer.write_at(socket.assigns.buffer, x, y, "X", %{fg_color: :red})
  {:noreply, assign(socket, buffer: buffer)}
end
```

### Paste Support

```elixir
<.live_component
  module={Raxol.LiveView.TerminalComponent}
  id="paste"
  buffer={@buffer}
  theme={:dracula}
  on_paste="handle_paste"
/>
```

---

## State Synchronization

### Two-Way Data Binding

Keep socket state in sync with terminal display:

```elixir
defmodule MyAppWeb.CounterLive do
  use MyAppWeb, :live_view
  alias Raxol.Core.{Buffer, Box}

  def mount(_params, _session, socket) do
    socket = assign(socket, buffer: Buffer.create_blank_buffer(40, 15), count: 0)
    {:ok, update_display(socket)}
  end

  def handle_event("increment", _, socket) do
    {:noreply, socket |> update(:count, &(&1 + 1)) |> update_display()}
  end

  def handle_info({:keypress, "+"}, socket) do
    handle_event("increment", nil, socket)
  end

  defp update_display(socket) do
    buffer =
      Buffer.create_blank_buffer(40, 15)
      |> Box.draw_box(0, 0, 40, 15, :double)
      |> Buffer.write_at(5, 6, "Count: #{socket.assigns.count}", %{fg_color: :green})

    assign(socket, buffer: buffer)
  end
end
```

### External State Changes

Subscribe to PubSub for external updates:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "system:stats")
  end

  {:ok, assign(socket, buffer: create_buffer(), stats: %{cpu: 0, memory: 0})}
end

def handle_info({:stats_updated, stats}, socket) do
  buffer =
    create_buffer()
    |> Buffer.write_at(5, 5, "CPU: #{stats.cpu}%", cpu_color(stats.cpu))
    |> Buffer.write_at(5, 7, "Memory: #{stats.memory}%", memory_color(stats.memory))

  {:noreply, assign(socket, buffer: buffer, stats: stats)}
end

defp cpu_color(cpu) when cpu > 80, do: %{fg_color: :red, bold: true}
defp cpu_color(cpu) when cpu > 50, do: %{fg_color: :yellow}
defp cpu_color(_), do: %{fg_color: :green}
```

---

## Multiple Terminals

### Split Screen

```elixir
def render(assigns) do
  ~H"""
  <div class="split-screen">
    <div class="left-panel">
      <.live_component
        module={Raxol.LiveView.TerminalComponent}
        id="left-terminal"
        buffer={@left_buffer}
        theme={:nord}
        on_keypress="handle_left_key"
      />
    </div>

    <div class="right-panel">
      <.live_component
        module={Raxol.LiveView.TerminalComponent}
        id="right-terminal"
        buffer={@right_buffer}
        theme={:dracula}
        on_keypress="handle_right_key"
      />
    </div>
  </div>
  """
end
```

---

## Error Boundaries

Catch rendering errors without crashing:

```elixir
def handle_info({:keypress, key}, socket) do
  case safe_update(socket, key) do
    {:ok, buffer} ->
      {:noreply, assign(socket, buffer: buffer, error: nil)}

    {:error, reason} ->
      Logger.error("Buffer update failed: #{inspect(reason)}")
      {:noreply, assign(socket, error: "Failed to process key: #{reason}")}
  end
end

defp safe_update(socket, key) do
  try do
    {:ok, Buffer.write_at(socket.assigns.buffer, 5, 10, "Last key: #{key}")}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
```

---

## Performance: Diff Rendering

`TerminalComponent` diffs buffers automatically on each render, so you do not need to track `previous_buffer` yourself. Simply assign the new buffer and the component handles the rest:

```elixir
def handle_info(:tick, socket) do
  frame = socket.assigns.frame + 1
  {:noreply, assign(socket, buffer: create_buffer(frame), frame: frame)}
end
```

### Debounced Updates

Avoid excessive re-renders:

```elixir
@debounce_ms 300

def handle_info({:keypress, key}, socket) do
  if socket.assigns.timer_ref do
    Process.cancel_timer(socket.assigns.timer_ref)
  end

  new_input = socket.assigns.input <> key
  timer_ref = Process.send_after(self(), :update_buffer, @debounce_ms)

  {:noreply, assign(socket, input: new_input, timer_ref: timer_ref)}
end

def handle_info(:update_buffer, socket) do
  {:noreply, assign(socket, buffer: create_buffer(socket.assigns.input), timer_ref: nil)}
end
```

---

## Animation Hints

When a TEA app uses `Raxol.Animation.Helpers.animate/2` in its `view/1`, the rendering engine passes those hints through to `TerminalBridge`, which emits CSS `transition` rules targeting `data-raxol-id` selectors. The browser handles interpolation, with no per-frame server re-renders needed.

```elixir
import Raxol.Animation.Helpers

def view(model) do
  box id: "panel", style: %{border: :single} do
    text("Hello")
  end
  |> animate(property: :opacity, from: 0.0, to: 1.0, duration: 300)
end
```

The generated HTML includes `data-raxol-id="panel"` on the relevant spans, and a `<style>` block with:

```css
[data-raxol-id="panel"] { transition: opacity 300ms cubic-bezier(0.33, 1, 0.68, 1) 0ms; }
@media (prefers-reduced-motion: reduce) {
  [data-raxol-id] { transition-duration: 0.01ms !important; }
}
```

`stagger/2` adds incrementing delays across a list of elements. `sequence/2` chains animations on a single element so they play one after another. Both are pure functions that attach metadata; they don't start server-side timers.

The terminal backend ignores hints entirely and relies on server-computed frames via `Animation.Framework`. MCP includes hints in `StructuredScreenshot` JSON so agents can see what's animating.

---

## CSS Customization

```css
.split-screen {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1rem;
  height: 600px;
}

.terminal-container {
  background: #1e1e1e;
  border-radius: 8px;
  padding: 1rem;
  box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
}
```

---

## Examples

- `examples/reference/liveview/tea_counter_live.ex`: TEA app rendered in the browser
- `examples/reference/liveview/01_simple_terminal/`: Step-by-step simple terminal

(These need a Phoenix host: they are reference modules, not `mix run` scripts.)

## Next Steps

- [Performance Cookbook](./PERFORMANCE_OPTIMIZATION.md)
- [Theming Cookbook](./THEMING.md)
- [API Reference](../core/BUFFER_API.md)
