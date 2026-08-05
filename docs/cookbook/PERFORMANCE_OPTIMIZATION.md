# Performance Optimization

Techniques for achieving 60fps terminal rendering.

## Performance Targets

| Operation         | Budget  | Typical | Excellent |
| ----------------- | ------- | ------- | --------- |
| Buffer create     | < 1ms   | 0.3ms   | 0.1ms     |
| write_at (single) | < 100us | 50us    | 20us      |
| draw_box          | < 500us | 240us   | 150us     |
| render_diff       | < 2ms   | 1.2ms   | 0.5ms     |
| Full render       | < 16ms  | 8ms     | 4ms       |
| LiveView update   | < 16ms  | 5ms     | 2ms       |

16ms per frame = 60fps.

---

## Buffer Diffing

Only update what changed.

```elixir
defmodule PerformantRenderer do
  alias Raxol.Core.{Buffer, Renderer}

  def render_loop(state) do
    new_buffer = create_frame(state)
    diff = Renderer.render_diff(state.buffer, new_buffer)
    IO.write(Renderer.apply_diff(diff))

    Process.sleep(16)  # ~60fps
    render_loop(%{state | buffer: new_buffer})
  end
end
```

Without diffing: ~15ms for 80x24 buffer (clear + full redraw). Diff rendering brings typical updates to ~2ms.

### Smart Diffing

Full render every N frames or when buffer dimensions change:

```elixir
defp major_change?(state, new_buffer) do
  rem(state.frame_count, 60) == 0 or
  state.buffer.width != new_buffer.width or
  state.buffer.height != new_buffer.height
end
```

---

## Caching Strategies

### Style Caching

Reuse style maps via module attributes (compile-time):

```elixir
@header_style Style.new(bold: true, fg_color: :cyan)
@error_style Style.new(bold: true, fg_color: :red)

def render_dashboard(buffer, data) do
  buffer
  |> Buffer.write_at(5, 1, "Dashboard", @header_style)
  |> Buffer.write_at(5, 3, data.message, message_style(data.status))
end

defp message_style(:ok), do: @success_style
defp message_style(:error), do: @error_style
defp message_style(_), do: %{}
```

10-20% faster by avoiding style allocation.

### Buffer Caching

Cache static parts of the UI:

```elixir
# Cache the static frame in a module attribute or process state
@main_frame Buffer.create_blank_buffer(80, 24)
            |> Box.draw_box(0, 0, 80, 24, :double)
            |> Buffer.write_at(10, 1, "My Application", %{bold: true})

# Only update dynamic content per render
@main_frame |> Buffer.write_at(10, 10, "Time: #{Time.utc_now()}")
```

---

## Lazy Rendering

Only render visible content.

### Viewport Rendering

```elixir
defmodule ViewportRenderer do
  def render_viewport(data, viewport) do
    buffer = Buffer.create_blank_buffer(viewport.width, viewport.height)

    data
    |> filter_visible(viewport)
    |> Enum.reduce(buffer, fn item, buf ->
      x = item.x - viewport.offset_x
      y = item.y - viewport.offset_y
      Buffer.write_at(buf, x, y, item.text, item.style)
    end)
  end
end
```

100x faster for large datasets (render 24 rows instead of 1000+).

### Virtual Scrolling

Only render visible rows in scrollable lists:

```elixir
def render_list(buffer, items, scroll_offset, visible_rows) do
  visible_items = Enum.slice(items, scroll_offset, visible_rows)

  visible_items
  |> Enum.with_index()
  |> Enum.reduce(buffer, fn {item, idx}, buf ->
    Buffer.write_at(buf, 2, idx + 2, format_item(item))
  end)
  |> add_scrollbar(scroll_offset, length(items), visible_rows)
end
```

---

## 60fps Checklist

- [ ] Use diff rendering. Don't redraw everything
- [ ] Cache static content. Reuse unchanged buffers
- [ ] Minimize allocations. Reuse style maps
- [ ] Batch updates. Group operations
- [ ] Lazy render. Only render visible content
- [ ] Profile regularly. Measure before optimizing
- [ ] Set frame budget. Warn if > 16ms
- [ ] Test on slow hardware

### Frame budget monitor

```elixir
defmodule FrameBudget do
  @fps_60_budget_us 16_000

  def render_with_budget(render_fn) do
    {time_us, result} = :timer.tc(render_fn)

    if time_us > @fps_60_budget_us do
      Logger.warn("Slow render: #{time_us}us (> #{@fps_60_budget_us}us)")
    end

    result
  end
end
```

---

## Common Pitfalls

### Creating styles repeatedly

```elixir
# Bad: new style map each iteration
Enum.each(lines, fn line ->
  Buffer.write_at(buffer, 0, line, "Text", %{fg_color: :cyan})
end)

# Good: reuse style
style = %{fg_color: :cyan}
Enum.reduce(lines, buffer, fn line, buf ->
  Buffer.write_at(buf, 0, line, "Text", style)
end)
```

30% faster for 100+ writes.

### Full redraws

```elixir
# Bad: clear and redraw everything
IO.write("\e[2J\e[H")
IO.puts(Buffer.to_string(buffer))

# Good: diff only changed cells
diff = Renderer.render_diff(old_buffer, new_buffer)
IO.write(Renderer.apply_diff(diff))
```

Diff rendering brings typical updates to ~2ms.

### Blocking in render loop

```elixir
# Bad: sync HTTP call in render loop
data = HTTPClient.get("/api/stats")  # blocks!

# Good: async fetch, render from cache
buffer = create_frame(state.cached_data)
```

---

## Profiling

### Manual

```elixir
{time, result} = :timer.tc(fn -> Buffer.create_blank_buffer(80, 24) end)
IO.puts("Create buffer: #{time}us (#{time / 1000}ms)")
```

### Benchee

```elixir
Benchee.run(%{
  "create_buffer" => fn -> Buffer.create_blank_buffer(80, 24) end,
  "draw_box" => fn -> Box.draw_box(buffer, 0, 0, 80, 24, :double) end,
  "diff_render" => fn ->
    new = Buffer.write_at(buffer, 40, 12, "X")
    Renderer.render_diff(buffer, new)
  end
}, time: 5, memory_time: 2)
```

### Performance Tests

```elixir
test "full frame render meets 60fps budget" do
  buffer = create_complex_frame()
  {time, _} = :timer.tc(fn -> Buffer.to_string(buffer) end)
  assert time < 16_000, "Full render too slow: #{time}us"
end
```

---

## Benchmarks

See `docs/bench/README.md` for the full benchmark suite comparing Raxol against Ratatui, Bubble Tea, and Textual.

## Next Steps

- [LiveView Cookbook](./LIVEVIEW_INTEGRATION.md)
- [Theming Cookbook](./THEMING.md)
- [API Reference](../core/BUFFER_API.md)
