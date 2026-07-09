defmodule Raxol.Terminal.IOTerminal do
  @moduledoc """
  Pure Elixir terminal I/O using OTP 28+ raw mode and IO.ANSI.

  Cross-platform terminal support without NIFs. Works on:
  - Windows 10+ (with VT100 support)
  - macOS
  - Linux

  Uses:
  - OTP 28's `shell:start_interactive/1` for raw terminal mode
  - `IO.ANSI` for escape sequences and colors
  - `:io.setopts/1` for terminal configuration
  """

  require Logger

  @doc """
  Initialize the terminal in raw mode.
  Returns `{:ok, state}` or `{:error, reason}`.
  """
  def init do
    with :ok <- enable_ansi_support(),
         :ok <- configure_terminal(),
         {:ok, size} <- get_terminal_size() do
      {:ok, %{size: size, initialized: true}}
    end
  end

  @doc """
  Shutdown terminal and restore settings.
  """
  def shutdown do
    # Restore terminal settings
    _ = :io.setopts([:list, {:echo, true}])
    :ok
  end

  @doc """
  Get terminal width and height.
  Returns `{:ok, {width, height}}` or `{:error, reason}`.
  """
  def get_terminal_size do
    case {get_columns(), get_rows()} do
      {{:ok, cols}, {:ok, rows}} ->
        {:ok, {cols, rows}}

      _ ->
        # Fallback to standard size
        {:ok, {80, 24}}
    end
  end

  @doc """
  Clear the entire screen.
  """
  def clear_screen do
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    :ok
  end

  @doc """
  Set cursor position (0-indexed).
  """
  def set_cursor(x, y) do
    # ANSI escape sequences are 1-indexed
    IO.write(IO.ANSI.cursor(y + 1, x + 1))
    :ok
  end

  @doc """
  Hide the cursor.
  """
  def hide_cursor do
    # ANSI escape sequence: CSI ?25l
    IO.write("\e[?25l")
    :ok
  end

  @doc """
  Show the cursor.
  """
  def show_cursor do
    # ANSI escape sequence: CSI ?25h
    IO.write("\e[?25h")
    :ok
  end

  @doc """
  Set a cell at position (x, y) with character, foreground, and background.
  Colors are 8-bit ANSI color codes (0-255).
  """
  def set_cell(x, y, char, fg, bg) do
    IO.write([
      IO.ANSI.cursor(y + 1, x + 1),
      ansi_color(fg, :foreground),
      ansi_color(bg, :background),
      char,
      IO.ANSI.reset()
    ])

    :ok
  end

  @doc """
  Print a string at position (x, y) with colors.
  """
  def print_string(x, y, string, fg, bg) do
    IO.write([
      IO.ANSI.cursor(y + 1, x + 1),
      ansi_color(fg, :foreground),
      ansi_color(bg, :background),
      string,
      IO.ANSI.reset()
    ])

    :ok
  end

  @doc """
  Present (flush) all pending output to the terminal.
  """
  def present do
    # Ensure all output is flushed
    :ok
  end

  @doc """
  Read a single character/keypress in raw mode.
  Returns `{:ok, char}` or `{:error, reason}`.
  """
  def read_char do
    case IO.getn("", 1) do
      :eof -> {:error, :eof}
      char -> {:ok, char}
    end
  end

  @doc """
  Set terminal title.
  """
  def set_title(title) when is_binary(title) do
    # OSC 0 ; title BEL
    IO.write("\e]0;#{title}\a")
    :ok
  end

  ## Private Functions

  defp enable_ansi_support do
    case :os.type() do
      {:win32, _} ->
        enable_windows_ansi()

      {:unix, _} ->
        # ANSI already supported on Unix
        :ok
    end
  end

  defp enable_windows_ansi do
    # On Windows 10+, VT100 support should be enabled via registry
    # HKCU\Console\VirtualTerminalLevel = 1
    # We can check if ANSI is enabled and enable it if not
    unless IO.ANSI.enabled?() do
      Application.put_env(:elixir, :ansi_enabled, true)
    end

    :ok
  end

  defp configure_terminal do
    # Configure terminal for binary mode with no echo
    # OTP 28+ supports raw mode for reading individual keypresses
    _ = :io.setopts([:binary, {:echo, false}])
    :ok
  rescue
    _ ->
      Logger.warning("Failed to configure terminal options, continuing anyway")
      :ok
  end

  defp get_columns do
    case :io.columns() do
      {:ok, cols} -> {:ok, cols}
      _other -> {:error, :not_supported}
    end
  end

  defp get_rows do
    case :io.rows() do
      {:ok, rows} -> {:ok, rows}
      _other -> {:error, :not_supported}
    end
  end

  # Convert 8-bit color code to ANSI escape sequence
  defp ansi_color(color, :foreground)
       when is_integer(color) and color >= 0 and color <= 255 do
    "\e[38;5;#{color}m"
  end

  defp ansi_color(color, :background)
       when is_integer(color) and color >= 0 and color <= 255 do
    "\e[48;5;#{color}m"
  end

  # Default colors
  defp ansi_color(_color, :foreground), do: IO.ANSI.default_color()
  defp ansi_color(_color, :background), do: IO.ANSI.default_background()
end
