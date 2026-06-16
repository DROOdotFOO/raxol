defmodule Raxol.Terminal.Rendering.OptimizedStyleRenderer do
  @moduledoc """
  Optimized terminal renderer with efficient style handling.

  Key optimizations:
  1. Pre-compiled style patterns at compile time
  2. Direct pattern matching instead of cache lookups
  3. Minimal memory allocations
  4. No process dictionary usage
  5. Efficient string building with iodata

  Target: <500μs render time (from current 1200-2600μs)
  """

  alias Raxol.Terminal.ScreenBuffer
  # alias Raxol.Terminal.Cell  # Not used currently
  alias Raxol.Terminal.ANSI.TextFormatting

  # Pre-compiled at compile time for zero runtime cost
  # @default_style %TextFormatting{}  # Not used currently

  # Common style patterns pre-compiled as binaries
  @style_patterns %{
    # Empty/default style
    {nil, nil, false, false, false} => "",

    # Basic colors (ANSI 16)
    {:black, nil, false, false, false} => "color:#000000",
    {:red, nil, false, false, false} => "color:#cc0000",
    {:green, nil, false, false, false} => "color:#4e9a06",
    {:yellow, nil, false, false, false} => "color:#c4a000",
    {:blue, nil, false, false, false} => "color:#3465a4",
    {:magenta, nil, false, false, false} => "color:#75507b",
    {:cyan, nil, false, false, false} => "color:#06989a",
    {:white, nil, false, false, false} => "color:#d3d7cf",

    # Bright colors
    {:bright_black, nil, false, false, false} => "color:#555753",
    {:bright_red, nil, false, false, false} => "color:#ef2929",
    {:bright_green, nil, false, false, false} => "color:#8ae234",
    {:bright_yellow, nil, false, false, false} => "color:#fce94f",
    {:bright_blue, nil, false, false, false} => "color:#729fcf",
    {:bright_magenta, nil, false, false, false} => "color:#ad7fa8",
    {:bright_cyan, nil, false, false, false} => "color:#34e2e2",
    {:bright_white, nil, false, false, false} => "color:#eeeeec",

    # Bold variants
    {nil, nil, true, false, false} => "font-weight:bold",
    {:red, nil, true, false, false} => "color:#cc0000;font-weight:bold",
    {:green, nil, true, false, false} => "color:#4e9a06;font-weight:bold",
    {:blue, nil, true, false, false} => "color:#3465a4;font-weight:bold",

    # Underline variants
    {nil, nil, false, false, true} => "text-decoration:underline",
    {:red, nil, false, false, true} => "color:#cc0000;text-decoration:underline",

    # Italic variants
    {nil, nil, false, true, false} => "font-style:italic"
  }

  @doc """
  Renders the screen buffer to HTML with optimized style handling.
  """
  def render(%ScreenBuffer{} = buffer, options \\ %{}) do
    cursor_pos = Map.get(options, :cursor, nil)

    buffer.cells
    |> render_cells_to_iodata()
    |> wrap_with_container()
    |> maybe_add_cursor(cursor_pos, buffer.width)
    |> IO.iodata_to_binary()
  end

  # Use iodata for efficient string building
  defp render_cells_to_iodata(cells) do
    cells
    |> Enum.with_index()
    |> Enum.map(fn {row, _y} ->
      render_row_optimized(row)
    end)
    |> Enum.intersperse("\n")
  end

  defp render_row_optimized(row) do
    # Group consecutive cells with same style
    row
    |> group_by_style()
    |> Enum.map(&render_styled_span/1)
  end

  defp group_by_style(row) do
    row
    |> Enum.chunk_by(& &1.style)
    |> Enum.map(fn cells ->
      style = hd(cells).style
      text = cells |> Enum.map(& &1.char) |> IO.iodata_to_binary()
      {style, text}
    end)
  end

  defp render_styled_span({style, text}) do
    case get_style_string_fast(style) do
      # No style needed
      "" -> text
      style_str -> ["<span style=\"", style_str, "\">", text, "</span>"]
    end
  end

  # Direct pattern matching for maximum performance
  defp get_style_string_fast(
         %TextFormatting{
           foreground: fg,
           background: bg,
           bold: bold,
           italic: italic,
           underline: underline
         } = style
       ) do
    # Try pre-compiled patterns first (most common cases)
    key = {fg, bg, bold, italic, underline}

    case Map.get(@style_patterns, key) do
      nil ->
        # Fall back to building style string for uncommon combinations
        build_style_string_minimal(style)

      style_str ->
        style_str
    end
  end

  # Minimal style string builder for uncommon cases
  defp build_style_string_minimal(%TextFormatting{} = style) do
    parts = []

    parts =
      case style.foreground do
        nil -> parts
        color -> [color_to_css(color, "color") | parts]
      end

    parts =
      case style.background do
        nil -> parts
        color -> [color_to_css(color, "background-color") | parts]
      end

    parts = if style.bold, do: ["font-weight:bold" | parts], else: parts
    parts = if style.italic, do: ["font-style:italic" | parts], else: parts

    parts =
      if style.underline, do: ["text-decoration:underline" | parts], else: parts

    parts =
      if style.strikethrough,
        do: ["text-decoration:line-through" | parts],
        else: parts

    Enum.join(parts, ";")
  end

  # Efficient color conversion with pattern matching
  defp color_to_css(color, property) when is_atom(color) do
    hex =
      case color do
        :black -> "#000000"
        :red -> "#cc0000"
        :green -> "#4e9a06"
        :yellow -> "#c4a000"
        :blue -> "#3465a4"
        :magenta -> "#75507b"
        :cyan -> "#06989a"
        :white -> "#d3d7cf"
        :bright_black -> "#555753"
        :bright_red -> "#ef2929"
        :bright_green -> "#8ae234"
        :bright_yellow -> "#fce94f"
        :bright_blue -> "#729fcf"
        :bright_magenta -> "#ad7fa8"
        :bright_cyan -> "#34e2e2"
        :bright_white -> "#eeeeec"
        _ -> "#ffffff"
      end

    "#{property}:#{hex}"
  end

  defp color_to_css({:rgb, r, g, b}, property) do
    "#{property}:rgb(#{r},#{g},#{b})"
  end

  defp color_to_css({:indexed, idx}, property) when idx in 0..255 do
    # Convert 256-color index to RGB
    hex = indexed_to_hex(idx)
    "#{property}:#{hex}"
  end

  defp color_to_css(_, property) do
    "#{property}:#ffffff"
  end

  # Pre-computed 256-color palette (first 16 entries shown, rest computed)
  defp indexed_to_hex(idx) when idx < 16 do
    # Standard ANSI colors
    case idx do
      0 -> "#000000"
      1 -> "#cc0000"
      2 -> "#4e9a06"
      3 -> "#c4a000"
      4 -> "#3465a4"
      5 -> "#75507b"
      6 -> "#06989a"
      7 -> "#d3d7cf"
      8 -> "#555753"
      9 -> "#ef2929"
      10 -> "#8ae234"
      11 -> "#fce94f"
      12 -> "#729fcf"
      13 -> "#ad7fa8"
      14 -> "#34e2e2"
      15 -> "#eeeeec"
    end
  end

  defp indexed_to_hex(idx) when idx < 232 do
    # 216-color cube (6x6x6)
    idx_offset = idx - 16
    r = div(idx_offset, 36) * 51
    g = rem(div(idx_offset, 6), 6) * 51
    b = rem(idx_offset, 6) * 51
    "##{to_hex(r)}#{to_hex(g)}#{to_hex(b)}"
  end

  defp indexed_to_hex(idx) do
    # Grayscale ramp
    gray = 8 + (idx - 232) * 10
    "##{to_hex(gray)}#{to_hex(gray)}#{to_hex(gray)}"
  end

  defp to_hex(n) do
    Integer.to_string(n, 16) |> String.pad_leading(2, "0")
  end

  defp wrap_with_container(content) do
    ["<pre class=\"terminal-output\">", content, "</pre>"]
  end

  defp maybe_add_cursor(content, nil, _width), do: content

  defp maybe_add_cursor(content, {y, x}, _width) do
    # Add cursor overlay element
    cursor_style =
      "position:absolute;left:#{x}ch;top:#{y}lh;width:1ch;height:1lh;background:rgba(255,255,255,0.5)"

    [content, "<div class=\"cursor\" style=\"", cursor_style, "\"></div>"]
  end
end
