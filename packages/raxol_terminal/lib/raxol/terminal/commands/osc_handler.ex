defmodule Raxol.Terminal.Commands.OSCHandler do
  @moduledoc """
  Consolidated OSC (Operating System Command) handler for terminal control sequences.
  Combines all OSC handler functionality including window, clipboard, color, and selection operations.
  """

  alias Raxol.Terminal.{Clipboard, Colors}

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
        Raxol.Core.Runtime.Log.warning("Unsupported OSC command: #{command}")
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
    Handles clipboard-related OSC commands.
    """

    alias Raxol.Terminal.Clipboard

    def handle_52(emulator, data) do
      case parse_52_command(data) do
        {:query, :clipboard} ->
          content = Clipboard.get_content(emulator.clipboard)
          response = format_clipboard_response(52, content)
          {:ok, %{emulator | output_buffer: response}}

        {:query, :selection} ->
          {:ok, content} = Clipboard.get_selection(emulator.clipboard)
          response = format_clipboard_response(52, content)
          {:ok, %{emulator | output_buffer: response}}

        {:set, :clipboard, content} ->
          {:ok, new_clipboard} =
            Clipboard.set_content(emulator.clipboard, content)

          {:ok, %{emulator | clipboard: new_clipboard}}

        {:set, :selection, content} ->
          {:ok, new_clipboard} =
            Clipboard.set_selection(emulator.clipboard, content)

          {:ok, %{emulator | clipboard: new_clipboard}}

        {:error, _reason} ->
          {:error, :invalid_clipboard_command, emulator}
      end
    end

    defp parse_52_command(data) do
      case String.split(data, ";", parts: 2) do
        ["c", "?"] -> {:query, :clipboard}
        ["s", "?"] -> {:query, :selection}
        ["c", content] -> {:set, :clipboard, decode_base64(content)}
        ["s", content] -> {:set, :selection, decode_base64(content)}
        _ -> {:error, :invalid_format}
      end
    end

    defp decode_base64(content) do
      case Base.decode64(content) do
        {:ok, decoded} -> decoded
        _ -> content
      end
    end

    defp format_clipboard_response(command, content) do
      encoded = Base.encode64(content)
      "\e]#{command};c;#{encoded}\e\\"
    end
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
    Handles color-related OSC commands.
    """

    alias Raxol.Terminal.Colors

    def handle_10(emulator, data) do
      case data do
        "?" -> handle_color_query(emulator, 10, &Colors.get_foreground/1)
        color_spec -> set_color(emulator, color_spec, &Colors.set_foreground/2)
      end
    end

    def handle_11(emulator, data) do
      case data do
        "?" -> handle_color_query(emulator, 11, &Colors.get_background/1)
        color_spec -> set_color(emulator, color_spec, &Colors.set_background/2)
      end
    end

    def handle_17(emulator, data) do
      case data do
        "?" ->
          handle_color_query(emulator, 17, &Colors.get_selection_background/1)

        color_spec ->
          set_color(emulator, color_spec, &Colors.set_selection_background/2)
      end
    end

    def handle_19(emulator, data) do
      case data do
        "?" ->
          handle_color_query(emulator, 19, &Colors.get_selection_foreground/1)

        color_spec ->
          set_color(emulator, color_spec, &Colors.set_selection_foreground/2)
      end
    end

    defp handle_color_query(emulator, command, getter) do
      color = getter.(emulator.colors)
      response = format_color_response(command, color)
      {:ok, %{emulator | output_buffer: response}}
    end

    defp set_color(emulator, color_spec, setter) do
      case Raxol.Terminal.Commands.OSCHandler.ColorParser.parse(color_spec) do
        {:ok, color} ->
          {:ok, new_colors} = setter.(emulator.colors, color)
          {:ok, %{emulator | colors: new_colors}}

        {:error, _reason} ->
          {:error, :invalid_color_spec, emulator}
      end
    end

    defp format_color_response(command, {r, g, b}) do
      "\e]#{command};rgb:#{format_hex(r)}/#{format_hex(g)}/#{format_hex(b)}\e\\"
    end

    defp format_hex(value) do
      Integer.to_string(value, 16) |> String.pad_leading(2, "0")
    end
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
          with {:ok, r} <- parse_hex_pair(String.slice(hex_string, 0, 2)),
               {:ok, g} <- parse_hex_pair(String.slice(hex_string, 2, 2)),
               {:ok, b} <- parse_hex_pair(String.slice(hex_string, 4, 2)) do
            {:ok, {r, g, b}}
          else
            _ -> {:error, :invalid_hex_format}
          end

        3 ->
          with {:ok, r} <- parse_hex_char(String.at(hex_string, 0)),
               {:ok, g} <- parse_hex_char(String.at(hex_string, 1)),
               {:ok, b} <- parse_hex_char(String.at(hex_string, 2)) do
            {:ok, {r * 17, g * 17, b * 17}}
          else
            _ -> {:error, :invalid_hex_format}
          end

        _ ->
          {:error, :invalid_hex_length}
      end
    end

    defp parse_hex_pair(pair) do
      case Integer.parse(pair, 16) do
        {value, ""} -> {:ok, value}
        _ -> {:error, :invalid_hex}
      end
    end

    defp parse_hex_char(char) do
      case Integer.parse(char, 16) do
        {value, ""} -> {:ok, value}
        _ -> {:error, :invalid_hex}
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
    Handles color palette OSC commands.
    """

    def handle_4(emulator, data) do
      case parse_palette_command(data) do
        {:set, index, color} ->
          set_palette_color(emulator, index, color)

        {:query, index} ->
          query_palette_color(emulator, index)

        {:reset, index} ->
          reset_palette_color(emulator, index)

        {:error, _reason} ->
          {:error, :invalid_palette_command, emulator}
      end
    end

    defp parse_palette_command(data) do
      case String.split(data, ";", parts: 2) do
        [index_str, "?"] ->
          case Integer.parse(index_str) do
            {index, ""} ->
              {:query, index}

            _ ->
              {:error, :invalid_index}
          end

        [index_str, color_spec] ->
          case Integer.parse(index_str) do
            {index, ""} ->
              if color_spec == "" do
                {:reset, index}
              else
                case Raxol.Terminal.Commands.OSCHandler.ColorParser.parse(
                       color_spec
                     ) do
                  {:ok, color} -> {:set, index, color}
                  error -> error
                end
              end

            _ ->
              {:error, :invalid_index}
          end

        _ ->
          {:error, :invalid_format}
      end
    end

    defp set_palette_color(emulator, index, color)
         when index >= 0 and index < 256 do
      palette = Map.put(emulator.palette, index, color)
      {:ok, %{emulator | palette: palette}}
    end

    defp set_palette_color(emulator, _index, _color) do
      {:error, :index_out_of_range, emulator}
    end

    defp query_palette_color(emulator, index) when index >= 0 and index < 256 do
      color = Map.get(emulator.palette, index, {0, 0, 0})
      response = format_palette_response(index, color)
      {:ok, %{emulator | output_buffer: response}}
    end

    defp query_palette_color(emulator, _index) do
      {:error, :index_out_of_range, emulator}
    end

    defp reset_palette_color(emulator, index) when index >= 0 and index < 256 do
      default_color = get_default_palette_color(index)
      palette = Map.put(emulator.palette, index, default_color)
      {:ok, %{emulator | palette: palette}}
    end

    defp reset_palette_color(emulator, _index) do
      {:error, :index_out_of_range, emulator}
    end

    defp get_default_palette_color(index) do
      # Return default ANSI color for the given index
      # This is a simplified version - actual defaults depend on terminal
      case index do
        # Black
        0 -> {0, 0, 0}
        # Red
        1 -> {205, 0, 0}
        # Green
        2 -> {0, 205, 0}
        # Yellow
        3 -> {205, 205, 0}
        # Blue
        4 -> {0, 0, 238}
        # Magenta
        5 -> {205, 0, 205}
        # Cyan
        6 -> {0, 205, 205}
        # White
        7 -> {229, 229, 229}
        # Default to black
        _ -> {0, 0, 0}
      end
    end

    defp format_palette_response(index, {r, g, b}) do
      "\e]4;#{index};rgb:#{format_hex(r)}/#{format_hex(g)}/#{format_hex(b)}\e\\"
    end

    defp format_hex(value) do
      Integer.to_string(value, 16) |> String.pad_leading(4, "0")
    end
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
      # Set current directory (for terminal tabs)
      {:ok, %{emulator | current_directory: data}}
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
          {:ok, %{emulator | remote_host: host}}

        "CurrentDir=" <> dir ->
          {:ok, %{emulator | current_directory: dir}}

        _ ->
          # Unsupported iTerm2 command
          {:ok, emulator}
      end
    end
  end

  # Selection sub-module
  defmodule Selection do
    @moduledoc """
    Handles selection-related OSC commands.
    """

    def handle_51(emulator, data) do
      case data do
        "?" ->
          # Query selection content
          content = Map.get(emulator, :selection_content, "")
          response = format_selection_response(content)
          {:ok, %{emulator | output_buffer: response}}

        content ->
          # Set selection content
          {:ok, %{emulator | selection_content: content}}
      end
    end

    defp format_selection_response(content) do
      encoded = Base.encode64(content)
      "\e]51;s;#{encoded}\e\\"
    end
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
              {:ok,
               %{family: family, size: size_val, style: parse_style(style)}}

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
