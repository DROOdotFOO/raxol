# Migration Guide: DIY to Raxol

Already built your own terminal rendering? This guide shows how to integrate or migrate to Raxol.

New to Raxol? See the [Quickstart](./QUICKSTART.md) first.

## Why Migrate?

You've built a working terminal renderer. Here's what Raxol adds on top:

**LiveView integration.** If you're rendering terminals in web apps, Raxol.LiveView handles buffer-to-HTML conversion, CSS theming (5 built-in themes), event handling, and 60fps rendering optimizations.

**Testing utilities.** Instead of fragile string matching against rendered output, you can test the actual data structure:

```elixir
buffer = Buffer.write_at(buffer, 5, 3, "expected text")
cell = Buffer.get_cell(buffer, 5, 3)
assert cell.char == "e"
```

**Performance optimizations.** Diff rendering (50x faster updates), benchmarking suite, memory profiling, automated regression detection.

You can adopt Raxol incrementally -- your existing code keeps working.

---

## Migration Strategies

### Strategy 1: Side-by-Side (lowest risk)

Run both implementations, compare outputs in dev/test:

```elixir
defmodule MyApp.Renderer do
  def render(data) do
    your_buffer = YourRenderer.create_buffer(data)
    your_output = YourRenderer.render(your_buffer)

    raxol_buffer = RaxolAdapter.from_your_format(your_buffer)
    raxol_output = Raxol.Core.Buffer.to_string(raxol_buffer)

    if Mix.env() != :prod do
      compare_outputs(your_output, raxol_output)
    end

    your_output
  end
end
```

Zero risk to production. Good for validating migration and finding edge cases. Doubled rendering cost in dev/test.

### Strategy 2: Feature Flagging

Gradually roll out Raxol:

```elixir
defmodule MyApp.Renderer do
  def render(data, opts \\ []) do
    if Keyword.get(opts, :use_raxol, false) ||
       Application.get_env(:my_app, :raxol_enabled, false) do
      render_with_raxol(data)
    else
      render_with_your_code(data)
    end
  end
end
```

Easy rollback. A/B testing possible. You maintain both paths until the switch is complete.

### Strategy 3: Module Replacement

Replace your module with a Raxol adapter:

```elixir
# Before:
defmodule MyApp.Buffer do
  def create(width, height), do: # your code
  def write_at(buffer, x, y, text), do: # your code
end

# After:
defmodule MyApp.Buffer do
  defdelegate create(width, height), to: Raxol.Core.Buffer, as: :create_blank_buffer
  defdelegate write_at(buffer, x, y, text), to: Raxol.Core.Buffer
  defdelegate write_at(buffer, x, y, text, style), to: Raxol.Core.Buffer

  # Keep custom functions
  def your_special_function(buffer), do: # your code
end
```

Minimal code changes. Keep your existing API.

### Strategy 4: Clean Break

Rewrite from scratch using Raxol. Simplest long-term, but highest risk. Best for small codebases or greenfield projects.

---

## Adapting Your Buffer Format

Most DIY implementations use similar structures. Here's a typical adapter:

```elixir
defmodule MyApp.BufferAdapter do
  def to_raxol(your_buffer) do
    raxol_buffer = Raxol.Core.Buffer.create_blank_buffer(
      your_buffer.width,
      your_buffer.height
    )

    Enum.reduce(your_buffer.cells, raxol_buffer, fn cell, buf ->
      style = %{
        fg_color: cell.fg,
        bg_color: Map.get(cell, :bg),
        bold: Map.get(cell, :bold, false)
      }
      Raxol.Core.Buffer.set_cell(buf, cell.x, cell.y, cell.char, style)
    end)
  end

  def from_raxol(raxol_buffer) do
    cells =
      for {line, y} <- Enum.with_index(raxol_buffer.lines),
          {cell, x} <- Enum.with_index(line.cells) do
        %{x: x, y: y, char: cell.char, fg: cell.style[:fg_color]}
      end

    %{width: raxol_buffer.width, height: raxol_buffer.height, cells: cells}
  end
end
```

Adapters add overhead. Benchmark both paths -- if the adapter is > 2x slower, consider Strategy 3 or 4.

---

## Incremental Migration

**Phase 1:** Add `{:raxol, "~> 2.4"}` to deps. Run tests, ensure no conflicts.

**Phase 2:** Create adapters. Write round-trip tests to verify conversions preserve data.

**Phase 3:** If you're using Phoenix, use `Raxol.LiveView.TerminalComponent` for web rendering. Keep your buffer code, convert via adapter.

**Phase 4:** Gradually replace custom components -- box drawing, text rendering, diffing -- with Raxol equivalents.

**Phase 5:** Once confidence is high, remove old code and adapters.

**Phase 6:** Add performance tracking. Log slow renders.

---

## Feature Parity Checklist

Before migrating, verify Raxol covers your needs:

- [ ] Create/write/read/clear/resize buffers
- [ ] Foreground/background colors (16, 256, RGB)
- [ ] Bold, italic, underline, strikethrough
- [ ] Box drawing (single, double, rounded, custom)
- [ ] Full and diff rendering
- [ ] ANSI and HTML output
- [ ] Unicode support (graphemes, wide chars, emoji)
- [ ] < 1ms buffer ops, < 16ms full renders

If something's missing, open a GitHub issue.

---

## FAQ

**Will this break my existing code?** No. Raxol runs alongside your code. Use adapters for gradual migration.

**What if Raxol is missing a feature I need?** Keep that part of your code, extend Raxol with a plugin, or open a GitHub issue.

**Can I contribute my adapter back?** Yes. Open a PR on [GitHub](https://github.com/DROOdotFOO/raxol).

---

## Resources

- [Quickstart](./QUICKSTART.md)
- [Core Concepts](./CORE_CONCEPTS.md)
- [API Reference](../core/BUFFER_API.md)
- [Cookbook](../cookbook/README.md)
- [GitHub Issues](https://github.com/DROOdotFOO/raxol/issues)
