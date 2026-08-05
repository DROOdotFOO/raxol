# Buffer API Reference

API reference for Raxol.Core buffer primitives. Note: raxol_core depends on telemetry at runtime.

## Raxol.Core.Buffer

Pure functional buffer operations for terminal rendering.

### Types

```elixir
@type cell :: %{char: String.t(), style: map()}
@type line :: %{cells: list(cell())}
@type t :: %{lines: list(line()), width: non_neg_integer(), height: non_neg_integer()}
```

### create_blank_buffer/2

```elixir
@spec create_blank_buffer(non_neg_integer(), non_neg_integer()) :: t()
```

Creates a blank buffer with the specified dimensions. All cells initialized to blank spaces.

```elixir
buffer = Raxol.Core.Buffer.create_blank_buffer(80, 24)
```

Performance: < 1ms for standard 80x24 buffer.

---

### write_at/5

```elixir
@spec write_at(t(), non_neg_integer(), non_neg_integer(), String.t(), map()) :: t()
```

Writes text at the specified coordinates with optional styling. Text wraps character-by-character, no automatic line breaks. Out-of-bounds writes are silently ignored. Unicode graphemes supported.

```elixir
buffer = Buffer.write_at(buffer, 5, 3, "Hello, World!")
buffer = Buffer.write_at(buffer, 5, 4, "Styled text", %{bold: true, fg_color: :blue})
```

Performance: < 1ms for typical strings.

---

### get_cell/3

```elixir
@spec get_cell(t(), non_neg_integer(), non_neg_integer()) :: cell() | nil
```

Retrieves the cell at the specified coordinates. Returns `nil` if out of bounds.

```elixir
cell = Buffer.get_cell(buffer, 5, 3)
# => %{char: "A", style: %{}}
```

Performance: O(1).

---

### set_cell/5

```elixir
@spec set_cell(t(), non_neg_integer(), non_neg_integer(), String.t(), map()) :: t()
```

Updates a single cell. More efficient than `write_at` for single characters. Out-of-bounds updates are silently ignored.

```elixir
buffer = Buffer.set_cell(buffer, 10, 5, "~", %{bg_color: :red})
```

Performance: < 100us.

---

### clear/1

```elixir
@spec clear(t()) :: t()
```

Resets all cells to blank. Returns new buffer with same dimensions.

---

### resize/3

```elixir
@spec resize(t(), non_neg_integer(), non_neg_integer()) :: t()
```

Resizes to new dimensions. Expanding fills with blank spaces. Shrinking crops from bottom and right. Existing content is preserved where it fits.

```elixir
buffer = Buffer.resize(buffer, 120, 40)  # expand
buffer = Buffer.resize(buffer, 40, 20)   # shrink (content cropped)
```

Performance: < 2ms for standard sizes.

---

### to_string/1

```elixir
@spec to_string(t()) :: String.t()
```

Converts buffer to a multi-line string. Styles are not rendered (use `Raxol.Core.Renderer` for styled output). Useful for testing and debugging.

---

## Raxol.Core.Renderer

Pure functional rendering and diffing.

### render_to_string/1

Renders buffer to plain ASCII string (no ANSI codes). < 1ms for 80x24 buffer.

### render_diff/2

```elixir
@spec render_diff(Buffer.t(), Buffer.t()) :: list()
```

Calculates minimal updates between two buffers. Returns a list of operation tuples:

- `{:move, x, y}` - Move cursor to position
- `{:write, text, style}` - Write text with style
- `{:clear_line, y}` - Clear line at y, emitted when a changed row becomes entirely blank (spaces with no visible style and no hyperlink). Rendered as `ESC[2K`, which erases the entire physical terminal row - buffers narrower than the terminal should not rely on the diff staying inside the buffer's width when a row goes blank.

```elixir
diff = Renderer.render_diff(old_buffer, new_buffer)
IO.write(Renderer.apply_diff(diff))
```

Only generates updates for changed cells. Batches consecutive changes into single writes; a row that goes fully blank collapses to a single `{:clear_line, y}`. < 2ms for 80x24 buffer.

### apply_diff/1

```elixir
@spec apply_diff(list()) :: String.t()
```

Converts diff operations to an ANSI output string with cursor movement and styling codes.

---

## Raxol.Core.Style

Style management and ANSI escape code generation.

### new/1

```elixir
style = Style.new(bold: true, fg_color: :blue)
```

Options: `:bold`, `:italic`, `:underline`, `:fg_color`, `:bg_color`.

### merge/2

```elixir
result = Style.merge(base, override)
# Second map wins on conflicts
```

### Color types

- Named: `:black`, `:red`, `:green`, `:yellow`, `:blue`, `:magenta`, `:cyan`, `:white`
- RGB: `Style.rgb(255, 100, 50)` returns `{255, 100, 50}`
- 256-color: `Style.color_256(196)` returns the palette index

### to_ansi/1

Converts style to ANSI escape codes: `Style.to_ansi(%{bold: true, fg_color: :blue})` => `"\e[1;34m"`.

---

## Raxol.Core.Box

Box drawing and area fill utilities.

### draw_box/6

```elixir
@spec draw_box(Buffer.t(), integer(), integer(), integer(), integer(), box_style()) :: Buffer.t()
```

Box styles:

- `:single` - Single line
- `:double` - Double line
- `:rounded` - Rounded corners
- `:heavy` - Bold lines
- `:dashed` - Dashed lines

Performance: 38-588us depending on size and style.

### draw_horizontal_line/5 and draw_vertical_line/5

Draw lines at specified coordinates with a given character.

### fill_area/7

```elixir
buffer = Box.fill_area(buffer, 10, 5, 20, 10, " ", %{bg_color: :blue})
buffer = Box.fill_area(buffer, 10, 5, 20, 10, ".", %{})
```

Performance: ~44us for 10x10, ~1.3ms for full 80x24.

---

## Performance targets

All operations designed for < 1ms on standard 80x24 buffers:

| Operation           | Target | Actual (avg) |
| ------------------- | ------ | ------------ |
| create_blank_buffer | < 1ms  | ~0.5ms       |
| write_at            | < 1ms  | ~0.1ms       |
| get_cell            | < 1ms  | ~0.001ms     |
| set_cell            | < 1ms  | ~0.1ms       |
| render_diff         | < 2ms  | ~2ms         |
| draw_box            | < 1ms  | 0.04-0.6ms   |
| fill_area (small)   | < 1ms  | 0.04ms       |

See `bench/core/` for detailed benchmarks.

## Error handling

All functions use defensive programming. Out-of-bounds coordinates are silently ignored. No exceptions for normal usage. Pattern matching validates input types at compile time.

## Thread Safety

All modules are pure functional with no shared state. Safe for concurrent use. No GenServers or processes. Immutable data structures throughout. Works in any context (LiveView, Phoenix, CLI, scripts).

## See Also

- [Architecture](./ARCHITECTURE.md)
