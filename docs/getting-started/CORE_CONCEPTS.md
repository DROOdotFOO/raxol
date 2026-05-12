# Core Concepts

The fundamentals of Raxol's architecture.

## The Elm Architecture (TEA)

Most Raxol apps use TEA, four callbacks that form a loop:

- **`init/1`**: Set up your initial state (the "model")
- **`update/2`**: Handle messages: keyboard events, button clicks, timers. Returns `{new_model, commands}`
- **`view/1`**: Build the UI from state. Called after every update
- **`subscribe/1`**: Set up recurring events (timers, data feeds)

State flows one direction. Views are pure functions of the model. Commands are how you request side effects (quitting, async work). If you've used Elm, Redux, or Bubble Tea, this will feel familiar.

Everything that arrives in `update/2` is a "message." That includes application atoms like `:increment`, timer ticks like `:tick`, and Raxol events like `%Event{type: :key, data: %{key: :enter}}`. They're all just inputs to the same function.

See the [Quickstart](QUICKSTART.md) for a full walkthrough, or browse the [Examples Learning Path](../../examples/README.md) for annotated examples from beginner to advanced.

---

## Buffers: The Canvas Underneath

Most Raxol apps never touch buffers directly. The View DSL and layout engine handle all of this for you. But understanding the layer underneath helps when debugging, optimizing, or building custom renderers.

A buffer is a 2D grid of cells representing terminal content, a canvas for text.

### Buffer Structure

```elixir
%{
  width: 80,
  height: 24,
  lines: [
    %{cells: [
      %{char: "H", style: %{fg_color: :cyan, bold: true}},
      %{char: "e", style: %{}},
      %{char: "l", style: %{}},
      # ... more cells
    ]},
    # ... more lines
  ]
}
```

Each buffer has width x height dimensions in characters. Lines are rows top to bottom. Each cell contains a `char` (single grapheme) and a `style` map (colors, bold, etc.).

### Immutable & Functional

```elixir
# Each operation returns a NEW buffer
new_buffer = Buffer.write_at(old_buffer, 5, 3, "Text")
# old_buffer is unchanged
```

No server processes required. Pure data structure operations. Optimal for diffing and caching.

### Cell Coordinates

Buffers use **(x, y)** coordinates, both 0-indexed:

```
(0,0) ────────────────> x (width)
  |
  |  (5,3) = Column 5, Row 3
  |
  v
  y (height)
```

```elixir
# Write "Hello" starting at column 10, row 5
buffer = Buffer.write_at(buffer, 10, 5, "Hello")
```

---

## The Rendering Pipeline

### Stage 1: Buffer Construction

Build the buffer by combining operations:

```elixir
buffer = Buffer.create_blank_buffer(80, 24)
  |> Box.draw_box(0, 0, 80, 24, :double)
  |> Buffer.write_at(10, 5, "Title", %{bold: true})
  |> Buffer.write_at(10, 7, "Content goes here")
```

Pure data transformation. No I/O, no side effects.

### Stage 2: Diffing

Calculate minimal changes between frames:

```elixir
diff = Renderer.render_diff(old_buffer, new_buffer)
# => [
#   {:move, 10, 7},
#   {:write, "Updated text", %{}},
# ]
```

Without diffing you'd clear and redraw everything. With diffing, only changed cells are written, bringing typical updates to ~2ms.

### Stage 3: Output Generation

```elixir
# Full output (for debugging)
IO.puts(Buffer.to_string(buffer))

# Diff output (for efficiency)
IO.write(Renderer.apply_diff(diff))

# HTML output (for web)
html = TerminalBridge.buffer_to_html(buffer)
```

### The Complete Pipeline

```
[User Code]
    |
    v
[Create Buffer] ────> Immutable data structure
    |
    v
[Apply Operations] ──> write_at, draw_box, fill_area
    |
    v
[Calculate Diff] ────> Compare with previous frame
    |
    v
[Generate Output] ───> ANSI codes / HTML / String
    |
    v
[Display] ───────────> Terminal / Browser / File
```

---

## State Management

**TEA is the canonical app model.** A Raxol application is a single module with `init/1`, `update/2`, and `view/1`, started via `Raxol.start_link/2`. One model, one update function, one view. Don't reach for alternatives unless TEA genuinely doesn't fit.

```elixir
defmodule MyApp do
  use Raxol.Core.Runtime.Application

  def init(_ctx), do: %{count: 0}

  def update(:inc, model), do: {%{model | count: model.count + 1}, []}

  def view(model) do
    column do
      [text("Count: #{model.count}"), button("+", on_click: :inc)]
    end
  end

  def subscribe(_model), do: []
end

Raxol.start_link(MyApp)
```

The same module renders to terminal, browser (LiveView via `Raxol.LiveView.TEALive`), SSH, and the MCP agent surface without changes. That's the whole point — one source of truth, four projections.

### When you don't need TEA

Two narrow cases call for something else:

**Pure rendering from a script.** You have data, you want a string. No loop, no input, no process. Use the buffer API directly:

```elixir
Buffer.create_blank_buffer(80, 24)
|> Box.draw_box(0, 0, 80, 24, :single)
|> Buffer.write_at(10, 5, "Count: #{data.count}")
|> Buffer.to_string()
|> IO.puts()
```

**You're embedding rendering inside an existing OTP process.** If you already have a GenServer or LiveView mount where Raxol is just one Component surface among many, you can call buffer ops directly from `handle_call` / `handle_event`. But if the *application* is the UI, wrap it in TEA and use a [`Raxol.LiveView.TEALive`](../cookbook/LIVEVIEW_INTEGRATION.md) mount or [`Raxol.SSH.serve/2`](../cookbook/SSH_DEPLOYMENT.md) instead — you'll get crash isolation, hot reload, and the agent surface for free.

Avoid hand-rolling your own `loop(state)` recursive function. That was a pre-Raxol pattern; OTP supervision and TEA's update loop subsume it.

---

## Performance Model

### Targets

| Operation         | Target  | Typical |
| ----------------- | ------- | ------- |
| Buffer create     | < 1ms   | 0.3ms   |
| write_at (single) | < 100us | 50us    |
| draw_box          | < 500us | 240us   |
| render_diff       | < 2ms   | 1.2ms   |
| Full render       | < 16ms  | 8ms     |

60 FPS = 16ms frame budget.

### Optimization Tips

**Pipeline operations** instead of intermediate variables. Elixir optimizes pipelines better.

**Use diff rendering.** Typical updates drop to ~2ms.

**Reuse style references.** Avoid allocating duplicate style maps.

**Use `fill_area`** instead of looping `set_cell`. Significantly faster for area fills.

### Memory

- Each cell: ~100 bytes (character + style)
- 80x24 buffer: ~192KB
- 200x50 buffer: ~1MB

Keep buffers reasonably sized. Don't hold references to old buffers you no longer need.

---

## Design Philosophy

**Functional first.** All buffer operations return new buffers, never mutate. Easier to reason about, no hidden side effects, safe for concurrent access.

**Composable.** Complex UIs are compositions of simple operations:

```elixir
def create_dashboard(buffer, data) do
  buffer
  |> draw_header(data.title)
  |> draw_sidebar(data.menu)
  |> draw_content(data.body)
  |> draw_footer(data.status)
end
```

**Minimal dependencies (core).** Raxol.Core depends only on telemetry at runtime. Minimal install size, no conflicts, works everywhere Elixir runs.

**Incremental adoption.** Use what you need. Buffers and rendering for scripts, the View DSL for interactive apps, or the full framework with LiveView and SSH.

---

## Common Questions

### Why not just write ANSI codes directly?

Buffers enable diffing. By maintaining the full state, we can calculate minimal updates instead of redrawing everything.

### Can I skip buffers entirely?

You can! Buffers are optional. But they give you automatic diffing, state inspection, HTML rendering, and testing utilities.

### How does Raxol compare to ncurses, Bubble Tea, etc.?

| Feature      | Raxol          | ncurses     | blessed    |
| ------------ | -------------- | ----------- | ---------- |
| Language     | Elixir         | C           | Node.js    |
| Paradigm     | Functional     | Imperative  | Imperative |
| Web Support  | Yes (LiveView) | No          | No         |
| Dependencies | telemetry      | System libs | Many       |

### Can I use Raxol alongside other libraries?

Yes. Raxol.Core is just data structures:

```elixir
buffer = Buffer.create_blank_buffer(80, 24)
  |> Buffer.write_at(10, 5, "Generated by Raxol")

output = Buffer.to_string(buffer)
MyCustomRenderer.render(output)
```

---

## Next Steps

- [Quickstart](QUICKSTART.md) - Build your first app
- [Migration Guide](./MIGRATION_FROM_DIY.md) - Integrate Raxol with existing code
- [Cookbook](../cookbook/README.md) - Practical patterns and recipes
- [API Reference](../core/BUFFER_API.md) - Complete function documentation
- [Architecture](../core/ARCHITECTURE.md) - Implementation details

For a full working example showing dashboard layout, live stats, and OTP differentiators, see `examples/demo.exs`.
