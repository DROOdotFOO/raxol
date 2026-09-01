# Raxol Terminal Subsystem

Handles terminal I/O, buffer management, parsing, cursor, and command execution.

## Modules

- `Raxol.Terminal.ScreenBuffer.Manager`: screen buffer (double buffering, damage tracking)
- `Raxol.Terminal.Cursor.Manager`: cursor state and movement
- `Raxol.Terminal.State.Manager`: terminal state and configuration
- `Raxol.Terminal.Commands.Manager`: command history
- `Raxol.Terminal.Commands.Executor`: command processing and execution
- `Raxol.Terminal.Style.Manager`: text styling and formatting
- `Raxol.Terminal.Emulator`: terminal emulation core
- `Raxol.Terminal.Integration`: connects and synchronizes components
- `Raxol.Terminal.ANSI`: escape sequence parsing

## Extension points

- Behaviours: `Raxol.Terminal.Driver.Behaviour`, `Raxol.Terminal.EmulatorBehaviour`,
  `Raxol.Terminal.OperationsBehaviour`, `Raxol.Terminal.ClipboardBehaviour`
- Public APIs: `Raxol.Terminal.Integration`, `Raxol.Terminal.Emulator`,
  `Raxol.Terminal.ScreenBuffer`

## Usage

`Raxol.Terminal.Integration` threads a `Raxol.Terminal.Integration.State`
struct through pure functions:

```elixir
state = Raxol.Terminal.Integration.init()
state = Raxol.Terminal.Integration.write(state, "Hello, World!")
state = Raxol.Terminal.Integration.move_cursor(state, 10, 5)
state = Raxol.Terminal.Integration.clear(state)
```

Queries:

```elixir
Raxol.Terminal.Integration.get_cursor_position(state)
Raxol.Terminal.Integration.get_visible_content(state)
state = Raxol.Terminal.Integration.resize(state, 120, 40)
```

The same module also runs as a manager process, in which case `write/2`,
`resize/3`, `clear/1`, and `handle_input/2` take a pid instead of a state.

## Known issues

### Credo stdin parsing warning

Credo may report `input_handler.ex` as unparseable. This is a Credo
limitation with stdin-related code, not a code problem. Safe to ignore or
exclude via `.credo.exs`:

```elixir
files: %{
  excluded: [~r"input_handler\.ex$"]
}
```

## References

- [Architecture](../../../../../docs/core/ARCHITECTURE.md)
- Module docs for implementation details
