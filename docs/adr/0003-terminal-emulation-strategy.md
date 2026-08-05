# ADR-0003: Terminal Emulation Strategy

## Status

Accepted

## Context

Raxol needs terminal emulation that also supports web deployment via Phoenix LiveView, sixel graphics, mouse input, true color, and Unicode/emoji. Traditional terminal emulators are tightly coupled to system TTY interfaces, which makes them hard to test, impossible to deploy to the web, and difficult to extend.

## Decision

A layered architecture that separates emulation from I/O and rendering.

1. **Core Emulator**: pure Elixir VT100/ANSI/xterm implementation
2. **Driver Layer**: pluggable backends (TTY, web, mock, test)
3. **Renderer Layer**: separate rendering from emulation logic
4. **Extension System**: plugin architecture for additional features

## Implementation

### Layers

```
+-------------------------------------+
|         Application Layer           |
|     (Components, Business Logic)    |
+-------------------------------------+
|         Emulator Core               |
|  (ANSI parsing, state management)   |
+-------------------------------------+
|         Driver Layer                |
|  (TTY | Web | Mock | Test)          |
+-------------------------------------+
|         Renderer Layer              |
|  (Terminal | HTML | Canvas)         |
+-------------------------------------+
```

### Driver Behaviour

```elixir
defmodule Raxol.Terminal.Driver.Behaviour do
  @callback start_link(dispatcher_pid :: pid()) :: {:ok, pid()}
  @callback write(pid(), iodata()) :: :ok
  @callback read(pid()) :: {:ok, binary()} | {:error, term()}
  @callback get_size(pid()) :: {:ok, {width :: pos_integer(), height :: pos_integer()}}
  @callback set_raw_mode(pid(), boolean()) :: :ok
end
```

### Backends

```elixir
# Native terminal (uses termbox2_nif when available)
defmodule Raxol.Terminal.Driver do
  @behaviour Raxol.Terminal.Driver.Behaviour
end

# Web (Phoenix Channels)
defmodule Raxol.Terminal.WebDriver do
  @behaviour Raxol.Terminal.Driver.Behaviour
end

# Testing (in-memory)
defmodule Raxol.Terminal.DriverMock do
  @behaviour Raxol.Terminal.Driver.Behaviour
end
```

The emulator core has zero dependencies on OS APIs, terminal I/O, rendering libraries, or network protocols. This means you can unit test without a terminal, deploy to the web without native dependencies, and develop on any platform.

### Feature modules

```elixir
# Sixel graphics: pure Elixir parser, renderers handle display
defmodule Raxol.Terminal.ANSI.SixelGraphics do
end

# Mouse: unified handling across backends
defmodule Raxol.Terminal.Mouse.Manager do
end

# Unicode: grapheme clusters, wide chars, emoji with fallbacks
defmodule Raxol.Terminal.Unicode do
end
```

## Consequences

### Positive

- Same code runs in terminal, browser, and tests
- Full test coverage without needing a TTY
- Adding new backends is straightforward
- Sixel, true color, and Unicode work everywhere

### Negative

- Multiple layers to understand
- Abstraction adds some overhead
- Some terminal-specific features may not translate to all backends

### Mitigation

- Clear layer boundaries with focused responsibilities
- EmulatorLite handles performance-critical paths
- Feature detection with graceful degradation

## Validation

```elixir
mix test                # works without a terminal
mix raxol.run           # native terminal
iex> Raxol.Web.start()  # browser
```

## Metrics

- Test coverage: 100% without requiring TTY
- Web feature parity: 100%
- Performance overhead: < 5% vs native terminals

## References

- XTerm Control Sequences: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
- VT100 User Guide: https://vt100.net/docs/vt100-ug/
- Sixel Graphics: https://github.com/saitoha/libsixel
