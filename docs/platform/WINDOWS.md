# Windows Platform Support

Raxol works on Windows through a pure Elixir terminal driver. No native compilation required.

**Status**: Supported (v2.0+)
**Backend**: Pure Elixir (IOTerminal) using OTP 28+ raw mode
**Requirements**: Windows 10+ with VT100 terminal emulation
**Performance**: ~500us per frame (plenty for 60fps)

## How It Works

Raxol picks the terminal backend automatically:

- **Unix/macOS**: Native termbox2 NIF (~50us/frame)
- **Windows**: Pure Elixir IOTerminal (~500us/frame)

No configuration needed. It just works.

## Requirements

- **Windows 10 or later** (for VT100 support)
- Windows Terminal (recommended), PowerShell 7+, or Windows PowerShell 5.1+
- **Erlang/OTP 28+** (for raw terminal mode)
- **Elixir 1.19+**

Windows 10+ has built-in VT100/ANSI escape sequence support, enabled by default in Windows Terminal, PowerShell, and cmd.exe.

## Installation

Standard installation, nothing special for Windows:

```powershell
# Add to mix.exs
{:raxol, "~> 2.4"}

# Install dependencies
mix deps.get

# Compile (NIF compilation is skipped on Windows)
mix compile
```

## Verification

```elixir
iex> Code.ensure_loaded?(Raxol.Terminal.IOTerminal)
true

iex> Code.ensure_loaded?(:termbox2_nif)
false  # Expected on Windows

iex> alias Raxol.Terminal.IOTerminal
iex> {:ok, state} = IOTerminal.init()
iex> IOTerminal.clear_screen()
:ok
iex> IOTerminal.set_cursor(10, 5)
:ok
iex> IOTerminal.shutdown()
:ok
```

## Features

Everything works the same on Windows:

- Screen clearing, cursor positioning, cell and string rendering
- Unicode characters, 256-color ANSI palette
- Raw keyboard input (OTP 28+ raw mode), mouse events, special keys
- Multi-framework UI (React, LiveView, HEEx, Raw)
- Component library, theme system, event handling, state management

## Performance

| Operation    | Windows (IOTerminal) | Unix (termbox2 NIF) |
| ------------ | -------------------- | ------------------- |
| Frame render | ~500us               | ~50us               |
| Screen clear | <100us               | <10us               |
| Set cursor   | <50us                | <5us                |
| Set cell     | <100us               | <10us               |

This is more than enough for 60fps terminal UIs (16ms frame budget), interactive apps, text editors, and dashboards.

## Terminal Emulators

### Windows Terminal (recommended)

Full unicode, true color (24-bit), GPU-accelerated rendering.

```powershell
winget install Microsoft.WindowsTerminal
```

### PowerShell

Both PowerShell 7+ (pwsh.exe) and Windows PowerShell 5.1 (powershell.exe) work well.

Enable ANSI colors if they're not already on:

```powershell
Get-ItemProperty HKCU:\Console VirtualTerminalLevel

# Enable VT100 if needed
Set-ItemProperty HKCU:\Console VirtualTerminalLevel -Type DWORD 1
```

### Command Prompt (cmd.exe)

Supported but limited. Unicode may have issues. Use Windows Terminal or PowerShell for a better experience.

## Troubleshooting

### Colors Not Displaying

```powershell
# Check VT100 status
reg query HKCU\Console /v VirtualTerminalLevel

# Enable if needed
reg add HKCU\Console /v VirtualTerminalLevel /t REG_DWORD /d 1 /f
```

### Unicode Characters Not Rendering

- Use a font that supports unicode (Cascadia Code, Consolas)
- Use Windows Terminal instead of cmd.exe
- Verify the system locale supports UTF-8

### Sluggish Rendering

- Use Windows Terminal (GPU-accelerated)
- Reduce UI complexity
- Batch rendering operations
- Profile with `mix raxol.perf`

### `:termbox2_nif` Errors on Windows

This is expected. Windows uses IOTerminal, not the NIF. Just make sure:

- `mix compile` completes without NIF build errors
- IOTerminal module is available
- No C compilation errors during `mix deps.compile`

## Running Tests

```powershell
mix test --exclude slow --exclude integration

# IOTerminal specifically
mix test test/raxol/terminal/io_terminal_test.exs

mix test --cover
```

## Debugging

```elixir
# config/dev.exs
config :logger, level: :debug
```

```elixir
require Logger
Logger.info("termbox2_nif available: #{Code.ensure_loaded?(:termbox2_nif)}")
Logger.info("IOTerminal available: #{Code.ensure_loaded?(Raxol.Terminal.IOTerminal)}")
```

## Implementation Details

### IOTerminal

Located in `lib/raxol/terminal/io_terminal.ex`. Uses `stty` and ANSI escape sequences via `IO.ANSI` for raw terminal mode, and cross-platform terminal size detection via `:io.columns/0` and `:io.rows/0`. Supports 256 colors and unicode.

API:

```elixir
IOTerminal.init()
IOTerminal.shutdown()
IOTerminal.clear_screen()
IOTerminal.set_cursor(x, y)
IOTerminal.hide_cursor()
IOTerminal.show_cursor()
IOTerminal.set_cell(x, y, char, fg, bg)
IOTerminal.print_string(x, y, str, fg, bg)
IOTerminal.get_terminal_size()
IOTerminal.set_title(title)
```

### Backend Selection

The Driver (`lib/raxol/terminal/driver.ex`) handles this automatically:

```elixir
@termbox2_available Code.ensure_loaded?(:termbox2_nif)

{_terminal_init_result, io_terminal_state} =
  if @termbox2_available do
    {apply(:termbox2_nif, :tb_init, []), nil}
  else
    case IOTerminal.init() do
      {:ok, io_state} -> {0, io_state}
      {:error, _reason} -> {-1, nil}
    end
  end
```

## Windows vs Unix Comparison

| Feature     | Windows (IOTerminal) | Unix (termbox2 NIF) |
| ----------- | -------------------- | ------------------- |
| Backend     | Pure Elixir          | Native C NIF        |
| OTP Version | 28+ required         | 26+ supported       |
| Compilation | No C compiler needed | Requires C compiler |
| Performance | Good (~500us)        | Excellent (~50us)   |
| Unicode     | Full support         | Full support        |
| Colors      | 256 colors           | 256 colors          |
| Mouse       | Supported            | Supported           |
| API         | Identical            | Identical           |

## Future Work

Potential optimizations, none currently needed:

- **Native Windows Console API NIF** -- would match Unix performance (~50us) but requires C compilation on Windows.
- **DirectWrite integration** -- GPU-accelerated text rendering with better font support.
- **ConPTY support** -- modern Windows pseudo-console, available in Windows 10 1809+.

## Resources

- [Windows Terminal Documentation](https://docs.microsoft.com/en-us/windows/terminal/)
- [Console Virtual Terminal Sequences](https://docs.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences)
- [Erlang/OTP 28 Raw Mode](https://www.erlang.org/doc/apps/stdlib/shell.html)
- [Raxol IOTerminal Tests](../../test/raxol/terminal/io_terminal_test.exs)

## Issues

If you hit problems: https://github.com/DROOdotFOO/raxol/issues

Include your Windows version, terminal emulator, Erlang/OTP version, Elixir version, and the error output.
