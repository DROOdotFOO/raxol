# Raxol LiveView - Web Terminal Rendering

High-performance Phoenix LiveView components for rendering terminal buffers in web browsers with 60fps capability.

## Features

- **60fps Rendering**: Optimized for real-time terminal updates (<16.67ms per frame)
- **Smart Caching**: Virtual DOM-style diffing with character-level caching
- **7 Built-in Themes**: synthwave84, nord, dracula, monokai, gruvbox, solarized, tokyo_night
- **Full VT100 Support**: All ANSI styles (bold, italic, underline, reverse, colors)
- **Telemetry Integration**: Performance monitoring via `:telemetry`
- **Accessibility**: ARIA attributes, screen reader support, keyboard navigation
- **CRT Effects**: Optional scanline and flicker effects for retro aesthetic

## Quick start

### Installation

```elixir
# In your LiveView
defmodule MyAppWeb.TerminalLive do
  use Phoenix.LiveView
  alias Raxol.LiveView.TerminalComponent

  def render(assigns) do
    ~H"""
    <.live_component
      module={TerminalComponent}
      id="my-terminal"
      buffer={@terminal_buffer}
      theme={:synthwave84}
      width={80}
      height={24}
    />
    """
  end
end
```

### Buffer Format

Buffers are simple Elixir maps:

```elixir
buffer = %{
  lines: [
    %{
      cells: [
        %{char: "H", style: %{fg_color: :green, bold: true}},
        %{char: "i", style: %{}}
      ]
    }
  ],
  width: 80,
  height: 24
}
```

## Architecture

### Core modules

#### `Raxol.LiveView.Renderer`

The rendering engine that converts terminal buffers to HTML.

**Key Functions:**
- `new/0` - Create a new renderer instance
- `render/2` - Render a buffer to HTML (returns `{html, updated_renderer}`)
- `stats/1` - Get cache performance statistics

**Performance:**
- First render: 0.39ms (2544fps) for 80x24
- Cached render: 0.0ms (instant)
- Diff render: 0.37-1.22ms
- Cache hit ratio: >90% for typical content

**Example:**
```elixir
renderer = Renderer.new()
{html, new_renderer} = Renderer.render(renderer, buffer)
stats = Renderer.stats(new_renderer)
# %{render_count: 1, cache_hits: 1850, cache_misses: 70, hit_ratio: 0.96}
```

#### `Raxol.LiveView.Themes`

Theme management with built-in and custom theme support.

**Built-in Themes:**
- `:synthwave84` - Retro synthwave colors (default)
- `:nord` - Nordic-inspired theme
- `:dracula` - Popular dark theme
- `:monokai` - Classic editor theme
- `:gruvbox` - Retro groove theme
- `:solarized_dark` - Solarized dark variant
- `:tokyo_night` - Modern dark theme

**API:**
```elixir
# Get a theme
{:ok, theme} = Themes.get_theme(:nord)

# Generate CSS
css = Themes.to_css(theme, ".my-terminal")

# Validate custom theme
case Themes.validate_theme(my_theme) do
  :ok -> :valid
  {:error, reason} -> :invalid
end
```

#### `Raxol.LiveView.TerminalComponent`

Phoenix LiveComponent for integrating terminals into LiveView.

**Props:**
- `id` (required) - Unique component ID
- `buffer` - Terminal buffer to render
- `theme` - Theme atom or custom map (default: `:synthwave84`)
- `width` - Terminal width in chars (default: 80)
- `height` - Terminal height in chars (default: 24)
- `crt_mode` - Enable CRT effects (default: false)
- `high_contrast` - High contrast mode (default: false)
- `aria_label` - Accessibility label (default: "Interactive terminal")
- `on_keypress` - Keyboard event handler name
- `on_cell_click` - Cell click event handler name

**Example with Events:**
```elixir
<.live_component
  module={TerminalComponent}
  id="terminal"
  buffer={@buffer}
  on_keypress="handle_key"
  on_cell_click="handle_click"
/>

def handle_event("handle_key", %{"key" => key}, socket) do
  # Process keyboard input
  {:noreply, socket}
end

def handle_event("handle_click", %{"row" => row, "col" => col}, socket) do
  # Process cell click
  {:noreply, socket}
end
```

## Telemetry

The renderer emits telemetry events for monitoring:

### Events

#### `[:raxol, :liveview, :render, :full]`
Emitted on first render of a buffer.

**Measurements:**
- `duration` - Render time in native time units
- `buffer_size` - Number of lines

**Metadata:**
- `width` - Terminal width
- `height` - Terminal height

#### `[:raxol, :liveview, :render, :cached]`
Emitted when returning cached HTML (buffer unchanged).

**Measurements:**
- `count` - Always 1

**Metadata:**
- `cache_hit` - Always true

#### `[:raxol, :liveview, :render, :diff]`
Emitted when re-rendering with buffer changes.

**Measurements:**
- `duration` - Render time
- `buffer_size` - Number of lines

**Metadata:**
- `width` - Terminal width
- `height` - Terminal height
- `cache_hit_ratio` - Character cache hit ratio (0.0-1.0)

#### `[:raxol, :liveview, :render, :error]`
Emitted when rendering fails.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `reason` - Error reason (`:nil_buffer` or `:validation_failed`)

### Telemetry setup

```elixir
:telemetry.attach(
  "raxol-liveview-stats",
  [:raxol, :liveview, :render, :diff],
  fn _event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info("""
    Render: #{duration_ms}ms
    Size: #{measurements.buffer_size} lines
    Cache: #{Float.round(metadata.cache_hit_ratio * 100, 1)}%
    """)
  end,
  nil
)
```

## Testing

### Unit tests

Test coverage by module:

- **Renderer**: 31 tests covering rendering, caching, styles, edge cases
- **Themes**: 20 tests for all built-in themes and validation
- **TerminalComponent**: 22 tests for component lifecycle and props

### Property-Based tests

Using StreamData for generative testing:

- **Buffer generation**: Tests with random dimensions (1-100 wide, 1-50 tall)
- **Cache behavior**: Verifies caching with repeated renders
- **ASCII handling**: All printable characters (32-126)
- **Invalid inputs**: Graceful handling of malformed buffers

Run tests:
```bash
mix test test/raxol/live_view/
```

### Benchmarks

Performance benchmarks verify 60fps capability:

```bash
mix run bench/live_view/renderer_bench.exs
```

Results on Apple Silicon:
- 80x24 first render: 0.39ms (2544fps) ✓
- 120x40 styled: 1.03ms (969fps) ✓
- Cached (no changes): 0.0ms (instant) ✓

## Performance guide

### Optimization tips

1. **Reuse Renderer Instances**
   ```elixir
   # Good - renderer state persists
   {html1, renderer2} = Renderer.render(renderer1, buffer1)
   {html2, renderer3} = Renderer.render(renderer2, buffer2)

   # Bad - loses cache benefit
   {html1, _} = Renderer.render(Renderer.new(), buffer1)
   {html2, _} = Renderer.render(Renderer.new(), buffer2)
   ```

2. **Minimize Buffer Changes**
   - Only update cells that changed
   - Identical buffers return cached HTML instantly

3. **Use Common Characters**
   - Pre-cached: space, A-Z, a-z, 0-9, common symbols
   - High cache hit ratio (>90%) for typical content

4. **Monitor Performance**
   ```elixir
   stats = Renderer.stats(renderer)
   if stats.hit_ratio < 0.8 do
     Logger.warning("Low cache hit ratio: #{stats.hit_ratio}")
   end
   ```

### Memory usage

- Renderer instance: ~10KB
- Cache grows with unique (char, style) combinations
- Call `Renderer.invalidate_cache/1` to reset if needed

## Examples

See `examples/reference/liveview/01_simple_terminal/simple_terminal_live.ex` for a complete working example.

## Migration from RaxolWeb

If upgrading from the old `RaxolWeb` namespace:

1. Update module names:
   ```diff
   - alias RaxolWeb.Renderer
   - alias RaxolWeb.Themes
   - alias RaxolWeb.LiveView.TerminalComponent
   + alias Raxol.LiveView.Renderer
   + alias Raxol.LiveView.Themes
   + alias Raxol.LiveView.TerminalComponent
   ```

2. Update test tags:
   ```diff
   - @moduletag :raxol_web
   + @moduletag :raxol_liveview
   ```

3. Update paths:
   ```diff
   - lib/raxol_web/
   - test/raxol_web/
   + lib/raxol/live_view/
   + test/raxol/live_view/
   ```

All functionality remains identical.

## Development

### Code Quality

- **Format**: `mix format lib/raxol/live_view/*.ex`
- **Warnings**: Zero with `--warnings-as-errors`
- **Type Specs**: 100% coverage on all functions
- **Tests**: 73 tests (67 unit + 6 properties), 100% passing

### Contributing

Follow Raxol coding standards:
- Functional patterns (pattern matching, guards, pipes)
- No imperative loops or nested conditionals
- Error handling with logging at boundaries
- Full @spec annotations

## License

Part of the Raxol project. See main LICENSE file.
