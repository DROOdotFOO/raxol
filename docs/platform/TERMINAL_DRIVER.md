# Terminal Driver Architecture

Raxol uses a hybrid terminal backend: a native NIF when available, with automatic fallback to pure Elixir.

## Overview

```
+-------------------+
|   Driver.ex       |  Automatic backend selection
+-------------------+
         |
    [compile-time check: @termbox2_available]
         |
    +----+----+
    |         |
    v         v
+-------+  +-----------+
|termbox|  |IOTerminal |  Pure Elixir fallback
|2_nif  |  |(OTP 28+)  |
+-------+  +-----------+
```

## How fallback works

### Compile-Time Detection

`Driver.ex` checks at compile time whether the termbox2_nif module is available:

```elixir
# packages/raxol_terminal/lib/raxol/terminal/driver.ex
@termbox2_available Code.ensure_loaded?(:termbox2_nif)
```

This module attribute gets baked into the BEAM bytecode, so there's no runtime overhead for the detection.

### Runtime backend selection

When `Driver` initializes, it picks the backend:

```elixir
{_result, io_terminal_state} =
  if @termbox2_available do
    {apply(:termbox2_nif, :tb_init, []), nil}
  else
    init_io_terminal()
  end
```

All subsequent operations follow the same pattern:

```elixir
defp get_termbox_width do
  if @termbox2_available do
    :termbox2_nif.tb_width()
  else
    case IOTerminal.get_terminal_size() do
      {:ok, {width, _height}} -> width
      _ -> 80
    end
  end
end
```

## Platform Support

| Platform        | Primary Backend | Fallback           | Performance  |
| --------------- | --------------- | ------------------ | ------------ |
| Linux           | termbox2_nif    | IOTerminal         | ~50us/frame  |
| macOS           | termbox2_nif    | IOTerminal         | ~50us/frame  |
| Windows 10+     | IOTerminal      | (primary)          | ~500us/frame |
| FreeBSD/OpenBSD | termbox2_nif    | IOTerminal         | ~50us/frame  |
| CI/Docker       | IOTerminal      | (no TTY detection) | N/A          |

## IOTerminal (Pure Elixir Backend)

When the NIF is unavailable, `IOTerminal` provides terminal support using:

- **Raw mode**: `stty` and ANSI sequences for reading keypresses
- **IO.ANSI**: Escape sequences for colors and cursor control
- **:io module**: Terminal configuration via `:io.setopts/1`

### Feature Comparison

| Feature            | termbox2_nif | IOTerminal  |
| ------------------ | ------------ | ----------- |
| Cursor positioning | Yes          | Yes         |
| 256-color support  | Yes          | Yes         |
| Terminal size      | Yes          | Yes         |
| Hide/show cursor   | Yes          | Yes         |
| Clear screen       | Yes          | Yes         |
| Raw key input      | Yes          | Yes\*       |
| Mouse events       | Yes          | Limited\*\* |
| Window title       | Yes          | Yes         |

\*Key input in IOTerminal uses `IO.getn/2` which may buffer differently.
\*\*Mouse support depends on terminal emulator ANSI support.

### Example Usage

```elixir
{:ok, state} = Raxol.Terminal.IOTerminal.init()

:ok = IOTerminal.clear_screen()
:ok = IOTerminal.set_cursor(10, 5)
:ok = IOTerminal.print_string(10, 5, "Hello", 46, 0)  # Green on black
{:ok, {width, height}} = IOTerminal.get_terminal_size()
:ok = IOTerminal.shutdown()
```

## TTY Detection

The driver checks whether it's running in a real TTY:

```elixir
def has_terminal_device? do
  case :io.getopts(:standard_io) do
    {:ok, opts} -> Keyword.get(opts, :terminal, false)
    _ -> false
  end
end
```

This prevents terminal initialization in CI pipelines, Docker containers without a TTY, and piped IEx sessions. The actual function name is `has_terminal_device?/0`.

## Terminal emulator compatibility

Raxol works with any terminal that supports basic ANSI escape sequences. Advanced features like inline images are auto-detected per-emulator.

| Emulator         | ANSI | Kitty Graphics | Notes                                |
| ---------------- | :--: | :------------: | ------------------------------------ |
| Ghostty          | yes  |      yes       | GPU-accelerated, full Kitty protocol |
| Kitty            | yes  |      yes       | Reference implementation             |
| WezTerm          | yes  |      yes       | Cross-platform                       |
| iTerm2           | yes  |    partial     | Uses iTerm2 image protocol instead   |
| Alacritty        | yes  |       no       | Fast, no image support               |
| Terminal.app     | yes  |       no       | macOS built-in                       |
| Windows Terminal | yes  |       no       | Needs VT100 enabled                  |
| xterm            | yes  |       no       | Sixel support available              |

Detection uses `TERM_PROGRAM` and `TERM` environment variables. See `Raxol.Terminal.Image.detect_protocol/0` and `Raxol.Terminal.ANSI.KittyGraphics.detect_support/0`.

## Graceful Degradation

When no TTY is available:

```elixir
@mix_env if Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod

# ...

case {@mix_env, has_terminal_device?()} do
  {:test, _} ->
    {:ok, state}

  {_, true} ->
    init_terminal_backend()

  {_, false} ->
    Log.warning("Not attached to a TTY. Terminal features disabled.")
    {:ok, state}
end
```

## Forcing a Backend

For testing or other specific cases:

```elixir
# In config/test.exs
config :raxol, :terminal_backend, :io_terminal

# At runtime
Application.put_env(:raxol, :terminal_backend, :io_terminal)
```

## Troubleshooting

### NIF not loading

If termbox2_nif fails to load:

1. Check you have a C toolchain:

   ```bash
   gcc --version
   make --version
   ```

2. On macOS in nix-shell, make sure TMPDIR is set:

   ```bash
   export TMPDIR=/tmp
   mix compile
   ```

3. Check the NIF build output:
   ```bash
   ls -la _build/dev/lib/termbox2_nif/priv/
   # Should contain termbox2_nif.so
   ```

### IOTerminal Issues

**No color output**: make sure ANSI is enabled:

```elixir
Application.put_env(:elixir, :ansi_enabled, true)
```

**Windows issues**: needs Windows 10+ with VT100 support enabled:

```
reg add HKCU\Console /v VirtualTerminalLevel /t REG_DWORD /d 1
```

**Raw mode not working**: requires OTP 28+. Check with `elixir --version`.

### Checking current backend

```elixir
iex> Code.ensure_loaded?(:termbox2_nif)
true  # Using NIF
false # Using IOTerminal

iex> Raxol.Terminal.Driver.backend()
:termbox2_nif
# or
:io_terminal
```

## Performance

| Operation           | termbox2_nif | IOTerminal | Notes      |
| ------------------- | ------------ | ---------- | ---------- |
| Initialize          | ~1ms         | ~2ms       |            |
| Set cell            | ~1us         | ~10us      | Per cell   |
| Full redraw (80x24) | ~50us        | ~500us     | 1920 cells |
| Get terminal size   | ~1us         | ~5us       |            |
| Read keypress       | ~1us         | ~10us      |            |

For most applications, IOTerminal performance is fine. The difference only matters with very high refresh rates (>30 fps), large terminals (>200x60), or intensive cell-by-cell updates.

## Related

- [Windows Platform Support](./WINDOWS.md)
- [Architecture Overview](../core/ARCHITECTURE.md)
- [Performance Targets](../bench/PERFORMANCE_TARGETS.md)
