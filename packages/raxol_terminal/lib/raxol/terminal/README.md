# Raxol Terminal Subsystem

Handles terminal I/O, buffer management, parsing, cursor, and command execution.

## Modules

- `Buffer.Manager`: screen buffer (double buffering, damage tracking)
- `Cursor.Manager`: cursor state and movement
- `State.Manager`: terminal state/configuration
- `Command.Manager`: command processing and execution
- `Style.Manager`: text styling and formatting
- `Emulator`: terminal emulation core
- `Integration`: connects and synchronizes components
- `ANSI`: escape sequence parsing

## Extension points

- Behaviours: `Driver.Behaviour`, `ScreenBuffer.Behaviour`, `Emulator.Behaviour`
- Public APIs: `Integration`, `Emulator`, `Buffer.Manager`

## Usage

```elixir
terminal = Raxol.Terminal.Integration.new(80, 24)
terminal = Raxol.Terminal.Integration.write(terminal, "Hello, World!")
terminal = Raxol.Terminal.Integration.move_cursor(terminal, 10, 5)
terminal = Raxol.Terminal.Integration.clear_screen(terminal)
```

Cursor management:

```elixir
terminal = Raxol.Terminal.Integration.set_cursor_style(terminal, :underline)
terminal = Raxol.Terminal.Integration.save_cursor(terminal)
terminal = Raxol.Terminal.Integration.restore_cursor(terminal)
```

Buffer operations:

```elixir
regions = Raxol.Terminal.Integration.get_damage_regions(terminal)
terminal = Raxol.Terminal.Integration.switch_buffers(terminal)
```

## Refactoring status

Ongoing restructuring to break large monolithic files into focused modules:

**Done:**
- `ansi.ex` (1257 lines) -> `ansi/parser.ex`, `ansi/emitter.ex`, `ansi/sequences/*.ex`, `ansi_facade.ex`
- `command_executor.ex` (1243 lines) -> `commands/executor.ex`, `commands/parser.ex`, `commands/modes.ex`, `commands/screen.ex`

**In progress:**
- `configuration.ex` (2394 lines) -> `config/` directory

**Planned:**
- `screen_buffer.ex` (1129 lines)
- `emulator.ex` (911 lines)
- `parser.ex` (1013 lines)

Facade modules maintain backward compatibility during the transition.

## Known issues

### Credo stdin parsing warning

Credo may report `lib/raxol/terminal/input_handler.ex` as unparseable. This is a Credo limitation with stdin-related code, not a code problem. Safe to ignore or exclude via `.credo.exs`:

```elixir
files: %{
  excluded: [~r"input_handler\.ex$"]
}
```

## References

- [Architecture](../../../../../docs/core/ARCHITECTURE.md)
- Module docs for implementation details
