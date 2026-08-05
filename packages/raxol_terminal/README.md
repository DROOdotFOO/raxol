# Raxol Terminal

Terminal emulation and driver infrastructure for Raxol. Depends on raxol_core for behaviours, events, and utilities.

## Install

```elixir
{:raxol_terminal, "~> 2.6"}
```

## What's included

- **ANSI**: Full ANSI/VT100 sequence parsing, graphics, mouse, Kitty protocol, Sixel
- **Buffer**: Screen buffer, cell operations, damage tracking
- **Commands**: CSI/OSC/DCS handlers, command executor
- **Config**: Terminal configuration, defaults, schema, persistence
- **Cursor**: Cursor state, movement, styling
- **Driver**: Platform detection (termbox2 NIF on Unix, pure Elixir on Windows)
- **Emulator**: Terminal emulation core, VT100 support
- **Input**: Input handling, mouse, keyboard, special keys
- **Parser**: Escape sequence parsing state machine
- **Rendering**: Terminal rendering, GPU, style caching
- **Screen Buffer**: Screen buffer implementation
- **Session**: Session serialization and storage
- **termbox2 NIF**: Bundled native interface (Unix only)

## Usage

GenServers defined here are started by the parent application's supervision tree.

```elixir
# In your Application supervisor
children = [
  Raxol.Terminal.Driver,
  Raxol.Terminal.Config.TerminalConfigManager
]
```

See [main docs](../../README.md) for the full Raxol framework.
