# ADR-0011: Terminal Module Consolidation

## Status

Implemented

## Context

The terminal subsystem had accumulated duplicates and dead code through organic growth:

- **Duplicate formatting**: `Raxol.Terminal.FormattingManager`, `Raxol.Terminal.Formatting.FormattingManager`, and scattered inline helpers all doing overlapping things.
- **Redundant mode managers**: `Mode.ModeManager`, `Modes.ModeStateManager`, `Cursor.OptimizedCursorManager`. Three modules for what should be one concern.
- **11 unused screen_buffer modules**: `cloud.ex`, `csi.ex`, `file_watcher.ex`, `metrics.ex`, `mode.ex`, `output.ex`, `preferences.ex`, `scroll.ex`, `system.ex`, `theme.ex`, `visualizer.ex`. Stubs with minimal or no usage.
- **No unified caching strategy** across terminal operations.

This made it unclear which module to use, created subtle behavioral differences between duplicate code paths, and made the codebase harder to contribute to.

## Decision

Consolidate into fewer, well-defined modules.

### Unified Formatting

`Raxol.Terminal.Format` becomes the single source for all text formatting:

```elixir
defmodule Raxol.Terminal.Format do
  def bold(text), do: ...
  def italic(text), do: ...
  def color(text, fg, bg \\ nil), do: ...
  def style(text, opts), do: ...
end
```

### Unified Caching

`Raxol.Performance.Cache` for all caching needs:

```elixir
defmodule Raxol.Performance.Cache do
  def get(key), do: ...
  def put(key, value, opts \\ []), do: ...
  def invalidate(key), do: ...
  def clear(), do: ...
end
```

### 16 Modules Deprecated

**Formatting (2)**: Both `FormattingManager` modules -> use `Raxol.Terminal.Format`

**Mode management (3)**: `Mode.ModeManager`, `Modes.ModeStateManager`, `Cursor.OptimizedCursorManager` -> use existing mode handling in emulator and `Raxol.Terminal.Cursor`

**Screen buffer (11)**: All `screen_buffer/*.ex` modules deprecated as unused stubs.

Each deprecated module got a `@moduledoc` notice pointing to the replacement, and will be removed in v3.0.

### GenServer Efficiency

The audit confirmed existing GenServers (ConfigServer, MetricsCollector) already use ETS backing efficiently. No process architecture changes needed.

## Migration

1. Create consolidated modules (done)
2. Add deprecation notices to old modules (done)
3. Update internal callers (in progress)
4. Remove deprecated modules in v3.0 (future)

## Consequences

### Positive

- One module per concern, no more guessing
- 16 fewer modules to maintain
- Clearer architecture for new contributors
- Unified caching enables better optimization
- Fewer code paths means more focused tests

### Negative

- Callers of deprecated modules need updates
- Must maintain deprecated modules until v3.0

### Mitigation

- Old modules continue to work during transition
- Deprecation warnings guide users to replacements
- Migration paths documented in module docs

## Validation

- 16 modules deprecated, 2 new created
- Net reduction of ~500 lines
- All existing tests pass
- New modules have 100% function coverage
- No performance regression in benchmarks
- Zero compile warnings from consolidation

## References

- [Terminal Format Module](../../lib/raxol/terminal/format.ex)
- [Performance Cache Module](../../lib/raxol/performance/cache.ex)
- [ADR-0003: Terminal Emulation Strategy](0003-terminal-emulation-strategy.md)

---

**Decision Date**: 2025-02-27
**Implementation Completed**: 2025-02-27
