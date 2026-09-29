defmodule Raxol.Terminal.Commands.OSCHandler do
  @moduledoc """
  Consolidated OSC (Operating System Command) handler for terminal control sequences.
  Combines all OSC handler functionality including window, clipboard, color, and selection operations.
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
        Logger.warning("Unsupported OSC command: #{inspect(command)}")
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

  # ColorParser sub-module
  defmodule ColorParser do
    @moduledoc """
    Parses color specifications from OSC commands.
    """

    def parse(color_spec) do
      cond do
        String.starts_with?(color_spec, "rgb:") ->
          parse_rgb(String.trim_leading(color_spec, "rgb:"))

        String.starts_with?(color_spec, "#") ->
          parse_hex(String.trim_leading(color_spec, "#"))

        true ->
          parse_name(color_spec)
      end
    end

    defp parse_rgb(rgb_string) do
      case String.split(rgb_string, "/") do
        [r, g, b] ->
          with {:ok, red} <- parse_component(r),
               {:ok, green} <- parse_component(g),
               {:ok, blue} <- parse_component(b) do
            {:ok, {red, green, blue}}
          else
            _ -> {:error, :invalid_rgb_format}
          end

        _ ->
          {:error, :invalid_rgb_format}
      end
    end

    defp parse_component(hex) do
      case Integer.parse(hex, 16) do
        {value, ""} when value >= 0 and value <= 255 -> {:ok, value}
        _ -> {:error, :invalid_component}
      end
    end

    defp parse_hex(hex_string) do
      case String.length(hex_string) do
        6 ->
          case Raxol.Terminal.Color.TrueColor.AnsiCodes.parse_hex_6(hex_string) do
            {:ok, r, g, b, _a} -> {:ok, {r, g, b}}
            {:error, _} -> {:error, :invalid_hex_format}
          end

        3 ->
          case Raxol.Terminal.Color.TrueColor.AnsiCodes.parse_hex_3(hex_string) do
            {:ok, r, g, b, _a} -> {:ok, {r, g, b}}
            {:error, _} -> {:error, :invalid_hex_format}
          end

        _ ->
          {:error, :invalid_hex_length}
      end
    end

    defp parse_name(name) do
      color_names = %{
        "black" => {0, 0, 0},
        "red" => {255, 0, 0},
        "green" => {0, 255, 0},
        "yellow" => {255, 255, 0},
        "blue" => {0, 0, 255},
        "magenta" => {255, 0, 255},
        "cyan" => {0, 255, 255},
        "white" => {255, 255, 255}
      }

      case Map.get(color_names, String.downcase(name)) do
        nil -> {:error, :unknown_color_name}
        color -> {:ok, color}
      end
    end
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

    def handle_7(emulator, data) do
      # Set current directory (for terminal tabs); bounded by the OSC string
      # cap (`Raxol.Terminal.Parser.ParserState`).
      {:ok, put_known(emulator, :current_directory, data)}
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
          {:ok, put_known(emulator, :remote_host, host)}

        "CurrentDir=" <> dir ->
          {:ok, put_known(emulator, :current_directory, dir)}

        _ ->
          # Unsupported iTerm2 command
          {:ok, emulator}
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

  # FontParser sub-module
  defmodule FontParser do
    @moduledoc """
    Parses font specifications from OSC commands.
    """

    def parse(font_spec) do
      case parse_font_components(font_spec) do
        {:ok, components} -> build_font_map(components)
        error -> error
      end
    end

    defp parse_font_components(spec) do
      parts = String.split(spec, ":")

      case parts do
        [family] ->
          {:ok, %{family: family}}

        [family, size] ->
          case Integer.parse(size) do
            {size_val, ""} -> {:ok, %{family: family, size: size_val}}
            _ -> {:error, :invalid_size}
          end

        [family, size, style] ->
          case Integer.parse(size) do
            {size_val, ""} ->
              {:ok, %{family: family, size: size_val, style: parse_style(style)}}

            _ ->
              {:error, :invalid_size}
          end

        _ ->
          {:error, :invalid_format}
      end
    end

    defp parse_style(style) do
      style
      |> String.downcase()
      |> case do
        "bold" -> :bold
        "italic" -> :italic
        "bolditalic" -> :bold_italic
        _ -> :regular
      end
    end

    defp build_font_map(components) do
      font =
        %{
          family: "monospace",
          size: 12,
          style: :regular
        }
        |> Map.merge(components)

      {:ok, font}
    end
  end

  # HyperlinkParser sub-module
  defmodule HyperlinkParser do
    @moduledoc """
    Parses hyperlink specifications from OSC 8 commands.
    """

    def parse(data) do
      case String.split(data, ";", parts: 2) do
        [params, url] ->
          parsed_params = parse_params(params)
          {:ok, url, parsed_params}

        _ ->
          {:error, :invalid_format}
      end
    end

    defp parse_params(params_string) do
      params_string
      |> String.split(":")
      |> Enum.map(&parse_param/1)
      |> Enum.filter(fn {k, _} -> k != nil end)
      |> Map.new()
    end

    defp parse_param(param) do
      case String.split(param, "=", parts: 2) do
        [key, value] -> {String.to_atom(key), value}
        _ -> {nil, nil}
      end
    end
  end

  # SelectionParser sub-module
  defmodule SelectionParser do
    @moduledoc """
    Parses selection specifications from OSC commands.
    """

    def parse(data) do
      case String.split(data, ";") do
        ["start", x1, y1, "end", x2, y2] ->
          with {x1_val, ""} <- Integer.parse(x1),
               {y1_val, ""} <- Integer.parse(y1),
               {x2_val, ""} <- Integer.parse(x2),
               {y2_val, ""} <- Integer.parse(y2) do
            {:ok, %{start: {x1_val, y1_val}, end: {x2_val, y2_val}}}
          else
            _ -> {:error, :invalid_coordinates}
          end

        _ ->
          {:error, :invalid_format}
      end
    end
  end
end
