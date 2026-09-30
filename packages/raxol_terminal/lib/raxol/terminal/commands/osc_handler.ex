defmodule Raxol.Terminal.Commands.OSCHandler do
  @moduledoc """
  Dispatches OSC (Operating System Command) sequences from the output stream.

  Handled: titles and icon names (OSC 0, 1, 2), the working directory (OSC 7
  and OSC 1337 `CurrentDir=`/`RemoteHost=`), hyperlinks (OSC 8),
  notifications and progress (OSC 9), and the pointer shape (OSC 22).
  Accepted and ignored: colours (OSC 4, 10, 11, 17, 19; no reply to a
  query), the clipboard and selection (OSC 52, 51; a query is never
  answered), and cursor colour and shape (OSC 12, 50, 112). Anything else is
  unsupported.
  """

  require Logger

  # Alias for backward compatibility
  def handle_osc_sequence(emulator, command, data) do
    handle(emulator, command, data)
  end

  def handle(emulator, command, data) do
    case get_command_group(command) do
      {:window, cmd} ->
        handle_window_ops(emulator, cmd, data)

      {:clipboard, cmd} ->
        handle_clipboard_ops(emulator, cmd, data)

      {:notification, cmd} ->
        handle_notification_ops(emulator, cmd, data)

      {:color, cmd} ->
        handle_color_ops(emulator, cmd, data)

      {:cursor, cmd} ->
        handle_cursor_ops(emulator, cmd, data)

      {:standalone, cmd} ->
        handle_standalone_ops(emulator, cmd, data)

      :unsupported ->
        Logger.debug("Unsupported OSC command: #{inspect(command)}")
        {:error, :unsupported_command, emulator}
    end
  end

  defp get_command_group(command) do
    command_groups = [
      {[0, 1, 2, 7, 8, 1337], :window},
      {[52], :clipboard},
      # OSC 9: desktop notification (iTerm2/growl); OSC 9;4 (data-prefixed):
      # taskbar/dock progress (ConEmu)
      {[9], :notification},
      {[10, 11, 17, 19], :color},
      {[12, 22, 50, 112], :cursor},
      {[4, 51], :standalone}
    ]

    result =
      Enum.find_value(command_groups, fn {commands, group} ->
        case command in commands do
          true -> {group, command}
          false -> nil
        end
      end)

    result || :unsupported
  end

  defp handle_standalone_ops(emulator, command, data) do
    case command do
      4 -> __MODULE__.ColorPalette.handle_4(emulator, data)
      51 -> __MODULE__.Selection.handle_51(emulator, data)
    end
  end

  defp handle_window_ops(emulator, command, data) do
    case command do
      0 -> __MODULE__.Window.handle_0(emulator, data)
      1 -> __MODULE__.Window.handle_1(emulator, data)
      2 -> __MODULE__.Window.handle_2(emulator, data)
      7 -> __MODULE__.Window.handle_7(emulator, data)
      8 -> __MODULE__.Window.handle_8(emulator, data)
      1337 -> __MODULE__.Window.handle_1337(emulator, data)
    end
  end

  defp handle_clipboard_ops(emulator, command, data) do
    case command do
      52 -> __MODULE__.Clipboard.handle_52(emulator, data)
    end
  end

  defp handle_notification_ops(emulator, command, data) do
    case command do
      9 -> __MODULE__.Notification.handle_9(emulator, data)
    end
  end

  defp handle_color_ops(emulator, command, data) do
    case command do
      10 -> __MODULE__.Color.handle_10(emulator, data)
      11 -> __MODULE__.Color.handle_11(emulator, data)
      17 -> __MODULE__.Color.handle_17(emulator, data)
      19 -> __MODULE__.Color.handle_19(emulator, data)
    end
  end

  defp handle_cursor_ops(emulator, command, data) do
    case command do
      # Set cursor color
      12 -> {:ok, emulator}
      # Set pointer/cursor shape
      22 -> __MODULE__.Pointer.handle_22(emulator, data)
      # Set cursor shape
      50 -> {:ok, emulator}
      # Reset cursor color
      112 -> {:ok, emulator}
      _ -> {:ok, emulator}
    end
  end

  def handle_window_title(emulator, data),
    do: {:ok, %{emulator | window_title: data}}

  def handle_icon_name(emulator, data),
    do: {:ok, %{emulator | icon_name: data}}

  # Clipboard sub-module
  defmodule Clipboard do
    @moduledoc """
    Handles OSC 52 (clipboard).

    Ignored. A query would hand the clipboard's contents to whatever program,
    or remote peer, writes the output stream, so it is never answered. A set
    has nowhere to go: the emulator keeps no clipboard of its own and has no
    opt-in to write the host's. Both used to raise, as the emulator has no
    `:clipboard` field.
    """

    def handle_52(emulator, _data), do: {:ok, emulator}
  end

  # Notification sub-module
  defmodule Notification do
    @moduledoc """
    Handles OSC 9 desktop notifications and OSC 9;4 taskbar/dock progress.
    """

    def handle_9(emulator, "4;" <> rest), do: handle_progress(emulator, rest)
    def handle_9(emulator, data), do: {:ok, %{emulator | notification: data}}

    defp handle_progress(emulator, rest) do
      case parse_progress(rest) do
        {:ok, state, value} ->
          {:ok, %{emulator | progress: %{state: state, value: value}}}

        {:error, _reason} ->
          {:error, :invalid_progress, emulator}
      end
    end

    defp parse_progress(rest) do
      case String.split(rest, ";", parts: 2) do
        [state_str, progress_str] ->
          parse_state_and_progress(state_str, progress_str)

        [state_str] ->
          parse_state_and_progress(state_str, "0")

        _ ->
          {:error, :invalid_format}
      end
    end

    defp parse_state_and_progress(state_str, progress_str) do
      with {state_code, ""} <- Integer.parse(state_str),
           {:ok, state} <- progress_state(state_code),
           {value, ""} <- Integer.parse(progress_str),
           true <- value >= 0 and value <= 100 do
        {:ok, state, value}
      else
        _ -> {:error, :invalid_progress}
      end
    end

    defp progress_state(0), do: {:ok, :remove}
    defp progress_state(1), do: {:ok, :set}
    defp progress_state(2), do: {:ok, :error}
    defp progress_state(3), do: {:ok, :indeterminate}
    defp progress_state(4), do: {:ok, :warning}
    defp progress_state(_), do: {:error, :invalid_state}
  end

  # Pointer sub-module
  defmodule Pointer do
    @moduledoc """
    Handles OSC 22 pointer/cursor shape.
    """

    def handle_22(emulator, "") do
      {:error, :invalid_pointer_shape, emulator}
    end

    def handle_22(emulator, shape) do
      {:ok, %{emulator | pointer_shape: shape}}
    end
  end

  # Color sub-module
  defmodule Color do
    @moduledoc """
    Handles OSC 10, 11, 17 and 19 (default foreground, background, selection
    background and foreground).

    Ignored: the emulator keeps no such colours to set or report, so a query
    gets no reply, and programs that ask (neovim asks for the background at
    startup) fall back to their defaults. Both used to raise, as the emulator
    has no `:colors` field.
    """

    def handle_10(emulator, _data), do: {:ok, emulator}
    def handle_11(emulator, _data), do: {:ok, emulator}
    def handle_17(emulator, _data), do: {:ok, emulator}
    def handle_19(emulator, _data), do: {:ok, emulator}
  end

  # ColorPalette sub-module
  defmodule ColorPalette do
    @moduledoc """
    Handles OSC 4 (palette colours).

    Ignored: the emulator has no palette model to set, reset or report from,
    so a query gets no reply. It used to raise, as the emulator has no
    `:palette` field.
    """

    def handle_4(emulator, _data), do: {:ok, emulator}
  end

  # Window sub-module
  defmodule Window do
    @moduledoc """
    Handles window-related OSC commands.
    """

    def handle_0(emulator, data) do
      # Set icon name and window title
      emulator = %{emulator | icon_name: data, window_title: data}
      {:ok, emulator}
    end

    def handle_1(emulator, data) do
      # Set icon name
      {:ok, %{emulator | icon_name: data}}
    end

    def handle_2(emulator, data) do
      # Set window title
      {:ok, %{emulator | window_title: data}}
    end

    # OSC 7 carries a `file://host/path` URI (percent-encoded). The decoded
    # path becomes `current_directory` and the host `remote_host`, but only
    # when the path is absolute and both are valid UTF-8 without C0 or C1
    # control characters (a UTF-8 U+009B is a CSI to some terminals);
    # anything else is ignored. Bounded by the OSC string cap
    # (`Raxol.Terminal.Parser.ParserState`).
    def handle_7(emulator, data) do
      with %URI{scheme: "file", path: "/" <> _ = path, host: host} <- URI.parse(data),
           {:ok, path} <- clean_text(URI.decode(path)),
           {:ok, host} <- clean_host(host) do
        {:ok, emulator |> put_known(:current_directory, path) |> put_known(:remote_host, host)}
      else
        _ -> {:ok, emulator}
      end
    end

    defp clean_host(nil), do: {:ok, nil}
    defp clean_host(""), do: {:ok, nil}
    defp clean_host(host), do: clean_text(URI.decode(host))

    # String.valid?/1 runs first, so the `u` regex never sees invalid UTF-8.
    defp clean_text(text) do
      if String.valid?(text) and not String.match?(text, ~r/[\x00-\x1F\x7F-\x9F]/u),
        do: {:ok, text},
        else: :error
    end

    def handle_8(emulator, data) do
      # Set hyperlink
      case parse_hyperlink(data) do
        {:ok, url, text} ->
          hyperlink = %{url: url, text: text}
          {:ok, %{emulator | current_hyperlink: hyperlink}}

        _ ->
          {:error, :invalid_hyperlink, emulator}
      end
    end

    def handle_1337(emulator, data) do
      # iTerm2 proprietary escape sequences
      handle_iterm2_command(emulator, data)
    end

    defp parse_hyperlink(data) do
      case String.split(data, ";", parts: 2) do
        [_params, url] -> {:ok, url, ""}
        _ -> {:error, :invalid_format}
      end
    end

    defp handle_iterm2_command(emulator, data) do
      case data do
        "RemoteHost=" <> host ->
          {:ok, put_clean(emulator, :remote_host, host)}

        "CurrentDir=" <> "/" <> rest ->
          {:ok, put_clean(emulator, :current_directory, "/" <> rest)}

        _ ->
          # Unsupported iTerm2 command
          {:ok, emulator}
      end
    end

    defp put_clean(emulator, key, value) do
      case clean_text(value) do
        {:ok, value} -> put_known(emulator, key, value)
        :error -> emulator
      end
    end

    # Only an emulator that has the field keeps the value.
    defp put_known(emulator, key, value) do
      if Map.has_key?(emulator, key), do: Map.put(emulator, key, value), else: emulator
    end
  end

  # Selection sub-module
  defmodule Selection do
    @moduledoc """
    Handles OSC 51 (selection).

    Ignored, like OSC 52: a query would hand the selection to the output
    stream's writer, and the emulator keeps no selection to set. Both used to
    raise, as the emulator has no `:selection_content` field.
    """

    def handle_51(emulator, _data), do: {:ok, emulator}
  end
end
