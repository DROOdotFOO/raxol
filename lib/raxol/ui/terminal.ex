defmodule Raxol.UI.Terminal do
  @moduledoc """
  A terminal UI rendering module for Raxol.

  This module provides basic terminal rendering capabilities for Raxol applications,
  with support for accessibility features, internationalization, and color system
  integration.

  ## Features

  - Terminal screen management (clearing, cursor positioning)
  - Text rendering with colors and styles
  - Input handling with support for keyboard shortcuts
  - Basic UI elements (boxes, lines, progress bars)
  - RTL rendering support
  - Accessibility-friendly output formatting
  """

  alias Raxol.Core.I18n
  alias Raxol.Style.Colors.System, as: ColorSystem

  @spec clear() :: :ok
  @doc """
  Clear the terminal screen.

  ## Examples

      iex> Terminal.clear()
      :ok
  """
  def clear do
    IO.write("\e[2J\e[H")
    :ok
  end

  @spec move_cursor(integer(), integer()) :: :ok
  @doc """
  Move the cursor to a specific position.

  ## Parameters

  * `row` - The row (1-indexed)
  * `col` - The column (1-indexed)

  ## Examples

      iex> Terminal.move_cursor(1, 1)
      :ok
  """
  def move_cursor(row, col) do
    IO.write("\e[#{row};#{col}H")
    :ok
  end

  @spec print(String.t(), keyword()) :: :ok
  @doc """
  Print text with optional styling.

  ## Options

  * `:color` - The text color (hex string or color name)
  * `:background` - The background color (hex string or color name)
  * `:bold` - Whether to display the text in bold (default: false)
  * `:italic` - Whether to display the text in italic (default: false)
  * `:underline` - Whether to underline the text (default: false)
  * `:dim` - Whether to display the text dimmed (default: false)
  * `:blink` - Whether to make the text blink (default: false)
  * `:rtl` - Whether to render the text right-to-left (default: from I18n)

  ## Examples

      iex> Terminal.print("Hello", color: "#FF0000", bold: true)
      :ok
  """
  def print(text, opts \\ []) do
    # Get RTL setting
    rtl = Keyword.get(opts, :rtl) || I18n.rtl?()

    # Format text for RTL if needed
    formatted_text = format_text_for_rtl(rtl, text)

    # Apply styles
    styled_text = apply_styles(formatted_text, opts)

    # Print the styled text
    IO.write(styled_text)
    :ok
  end

  @spec println(String.t(), keyword()) :: :ok
  @doc """
  Print text followed by a newline.

  Takes the same options as `print/2`.

  ## Examples

      iex> Terminal.println("Hello", color: "#FF0000", bold: true)
      :ok
  """
  def println(text \\ "", opts \\ []) do
    print(text, opts)
    IO.write("\n")
    :ok
  end

  @spec print_centered(String.t(), keyword()) :: :ok
  @doc """
  Print centered text.

  ## Options

  Takes the same options as `print/2`.

  ## Examples

      iex> Terminal.print_centered("Title", color: "#FF0000", bold: true)
      :ok
  """
  def print_centered(text, opts \\ []) do
    # Get terminal width
    width = get_terminal_size().width

    # Calculate padding from display width so CJK/emoji center correctly
    padding =
      max(0, div(width - Raxol.UI.TextMeasure.display_width(text), 2))

    # Print with padding
    print(String.duplicate(" ", padding) <> text, opts)
    :ok
  end

  @spec print_horizontal_line(keyword()) :: :ok
  @doc """
  Print a horizontal line spanning the terminal width.

  ## Options

  * `:char` - The character to use for the line (default: "─")
  * Other options are passed to `print/2`

  ## Examples

      iex> Terminal.print_horizontal_line(char: "-", color: "#CCCCCC")
      :ok
  """
  def print_horizontal_line(opts \\ []) do
    # Get terminal width
    width = get_terminal_size().width

    # Get line character
    char = Keyword.get(opts, :char, "─")

    # Print the line
    print(String.duplicate(char, width), opts)
    :ok
  end

  @spec read_key(keyword()) :: {:ok, term()} | :timeout | {:error, term()}
  @doc """
  Read a keypress from the user.

  ## Options

  * `:timeout` - Timeout in milliseconds (default: :infinity)

  ## Returns

  * `{:ok, key}` - Where key is the key pressed
  * `:timeout` - If no key was pressed within the timeout
  * `{:error, reason}` - If an error occurred

  ## Examples

      iex> Terminal.read_key()
      {:ok, :enter}

      iex> Terminal.read_key(timeout: 1000)
      :timeout
  """
  def read_key(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    original_opts = :io.getopts()

    _ = :io.setopts([{:binary, true}, {:echo, false}, {:raw, true}])

    result = handle_key_input(timeout)
    _ = :io.setopts(original_opts)
    result
  end

  defp handle_key_input(timeout) do
    receive do
      {:io_request, from, reply_as, {:get_chars, _, _, 1}} ->
        handle_char_request(from, reply_as)

      {:io_request, from, reply_as, req} ->
        handle_other_io_request(from, reply_as, req)
    after
      timeout -> :timeout
    end
  end

  defp handle_char_request(from, reply_as) do
    chars = :io.get_chars("", 1)
    _ = send(from, {:io_reply, reply_as, chars})
    parse_char_result(chars)
  end

  defp handle_other_io_request(from, reply_as, req) do
    reply = :io.request(req)
    _ = send(from, {:io_reply, reply_as, reply})
    {:error, :unsupported_io_request}
  end

  defp parse_char_result(chars) do
    case chars do
      :eof -> {:error, :eof}
      {:error, reason} -> {:error, reason}
      data when is_binary(data) -> {:ok, parse_key(data)}
      _ -> {:error, :unknown_reply}
    end
  end

  @spec print_box(String.t(), keyword()) :: :ok
  @doc """
  Print a box with content.

  ## Parameters

  * `content` - The text content to display inside the box
  * `opts` - Styling options

  ## Options

  * `:width` - Box width (default: content width + 4)
  * `:height` - Box height (default: content lines + 2)
  * `:border_color` - Color for the border
  * `:title` - Optional title for the box
  * `:title_color` - Color for the title
  * `:centered` - Whether to center the box horizontally (default: false)

  ## Examples

      iex> Terminal.print_box("Hello\nWorld", title: "Greeting", border_color: "#0000FF")
      :ok
  """
  def print_box(content, opts \\ []) do
    lines = String.split(content, "\n")
    dimensions = calculate_box_dimensions(lines, opts)
    box_config = build_box_config(opts, dimensions)

    print_box_borders(box_config)
    print_box_content(lines, box_config)
    :ok
  end

  defp calculate_box_dimensions(lines, opts) do
    content_width = Enum.max_by(lines, &String.length/1) |> String.length()
    content_height = length(lines)
    width = Keyword.get(opts, :width, content_width + 4)
    height = Keyword.get(opts, :height, content_height + 2)

    %{width: width, height: height, content_width: content_width}
  end

  defp build_box_config(opts, dimensions) do
    %{
      width: dimensions.width,
      title: Keyword.get(opts, :title),
      border_color: Keyword.get(opts, :border_color),
      title_color:
        Keyword.get(opts, :title_color, Keyword.get(opts, :border_color)),
      centered: Keyword.get(opts, :centered, false)
    }
  end

  defp print_box_borders(config) do
    top_border = "┌" <> String.duplicate("─", config.width - 2) <> "┐"
    print_border_line(top_border, config)

    print_title_if_present(config.title, config)
  end

  defp print_border_line(border, config) do
    print_border_with_centering(config.centered, border, config.border_color)
  end

  defp print_title(config) do
    title_line =
      "│ " <> String.pad_trailing(config.title, config.width - 4) <> " │"

    print_border_line(title_line, config)

    separator = "├" <> String.duplicate("─", config.width - 2) <> "┤"
    print_border_line(separator, config)
  end

  defp print_box_content(lines, config) do
    Enum.each(lines, fn line ->
      line_str = "│ " <> String.pad_trailing(line, config.width - 4) <> " │"
      print_border_line(line_str, config)
    end)

    bottom_border = "└" <> String.duplicate("─", config.width - 2) <> "┘"
    print_border_line(bottom_border, config)
  end

  # Private functions

  defp apply_styles(text, opts) do
    style_codes = build_style_codes(opts)
    format_text_with_styles(text, style_codes)
  end

  defp build_style_codes(opts) do
    []
    |> add_color_codes(opts)
    |> add_background_codes(opts)
    |> add_text_style_codes(opts)
  end

  defp add_color_codes(codes, opts) do
    case Keyword.get(opts, :color) do
      nil ->
        codes

      color when is_atom(color) ->
        [fg_color_code(ColorSystem.get_color(color)) | codes]

      hex ->
        [fg_color_code(hex) | codes]
    end
  end

  defp add_background_codes(codes, opts) do
    case Keyword.get(opts, :background) do
      nil ->
        codes

      color when is_atom(color) ->
        [bg_color_code(ColorSystem.get_color(color)) | codes]

      hex ->
        [bg_color_code(hex) | codes]
    end
  end

  defp add_text_style_codes(codes, opts) do
    style_mappings = [
      {:bold, "1"},
      {:italic, "3"},
      {:underline, "4"},
      {:dim, "2"},
      {:blink, "5"}
    ]

    Enum.reduce(style_mappings, codes, fn {key, code}, acc ->
      add_style_code_if_enabled(Keyword.get(opts, key, false), code, acc)
    end)
  end

  defp format_text_with_styles(text, []) do
    text
  end

  defp format_text_with_styles(text, style_codes) do
    codes = Enum.join(style_codes, ";")
    "\e[#{codes}m#{text}\e[0m"
  end

  defp fg_color_code(hex) do
    {r, g, b} = hex_to_rgb(hex)
    "38;2;#{r};#{g};#{b}"
  end

  defp bg_color_code(hex) do
    {r, g, b} = hex_to_rgb(hex)
    "48;2;#{r};#{g};#{b}"
  end

  defp hex_to_rgb(hex), do: Raxol.Utils.ColorConversion.hex_to_rgb(hex)

  defp parse_key(data) do
    key_mappings = %{
      # Control keys
      "\r" => :enter,
      "\n" => :enter,
      " " => :space,
      "\t" => :tab,
      "\e" => :escape,
      "\b" => :backspace,
      "\x7F" => :backspace,
      "\x03" => :ctrl_c,
      "\x04" => :ctrl_d,
      # Arrow keys
      "\e[A" => {:arrow, :up},
      "\e[B" => {:arrow, :down},
      "\e[C" => {:arrow, :right},
      "\e[D" => {:arrow, :left},
      # Function keys
      "\e[11~" => :f1,
      "\e[12~" => :f2,
      "\e[13~" => :f3,
      "\e[14~" => :f4
    }

    case Map.get(key_mappings, data) do
      nil ->
        # Handle regular characters
        case data do
          <<char::utf8, _rest::binary>> -> {:char, <<char::utf8>>}
          _ -> {:unknown, data}
        end

      key ->
        key
    end
  end

  defp get_terminal_size do
    case :io.columns() do
      {:ok, width} ->
        case :io.rows() do
          {:ok, height} -> %{width: width, height: height}
          # Default height
          _ -> %{width: 80, height: 24}
        end

      # Default size
      _ ->
        %{
          width: Raxol.Core.Defaults.terminal_width(),
          height: Raxol.Core.Defaults.terminal_height()
        }
    end
  end

  # Helper functions for pattern matching instead of if statements

  defp format_text_for_rtl(true, text) do
    # Basic RTL formatting - in a real implementation this would be more sophisticated
    String.reverse(text)
  end

  defp format_text_for_rtl(false, text), do: text

  defp print_title_if_present(nil, _config), do: :ok
  defp print_title_if_present(_title, config), do: print_title(config)

  defp print_border_with_centering(true, border, border_color) do
    print_centered(border, color: border_color)
    println()
  end

  defp print_border_with_centering(false, border, border_color) do
    println(border, color: border_color)
  end

  defp add_style_code_if_enabled(true, code, acc), do: [code | acc]
  defp add_style_code_if_enabled(false, _code, acc), do: acc
end
