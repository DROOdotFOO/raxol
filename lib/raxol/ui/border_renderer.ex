defmodule Raxol.UI.BorderRenderer do
  @moduledoc """
  Handles border rendering logic and border character definitions.
  """

  @type border_style :: :single | :double | :rounded | :ascii | :none
  @type border_chars :: %{
          top_left: String.t(),
          top_right: String.t(),
          bottom_left: String.t(),
          bottom_right: String.t(),
          horizontal: String.t(),
          vertical: String.t()
        }
  @type border_chars_8key :: %{
          top_left: String.t(),
          top: String.t(),
          top_right: String.t(),
          left: String.t(),
          right: String.t(),
          bottom_left: String.t(),
          bottom: String.t(),
          bottom_right: String.t()
        }
  @type cell :: {integer(), integer(), String.t(), atom(), atom(), list()}

  @doc """
  Gets border characters for a given border style.
  """
  @spec get_border_chars(border_style()) :: border_chars()
  def get_border_chars(:single) do
    %{
      top_left: "┌",
      top_right: "┐",
      bottom_left: "└",
      bottom_right: "┘",
      horizontal: "─",
      vertical: "│"
    }
  end

  def get_border_chars(:double) do
    %{
      top_left: "╔",
      top_right: "╗",
      bottom_left: "╚",
      bottom_right: "╝",
      horizontal: "═",
      vertical: "║"
    }
  end

  def get_border_chars(:rounded) do
    %{
      top_left: "╭",
      top_right: "╮",
      bottom_left: "╰",
      bottom_right: "╯",
      horizontal: "─",
      vertical: "│"
    }
  end

  def get_border_chars(:ascii) do
    %{
      top_left: "+",
      top_right: "+",
      bottom_left: "+",
      bottom_right: "+",
      horizontal: "-",
      vertical: "|"
    }
  end

  def get_border_chars(:none) do
    %{
      top_left: " ",
      top_right: " ",
      bottom_left: " ",
      bottom_right: " ",
      horizontal: " ",
      vertical: " "
    }
  end

  # Fallback for unknown styles
  def get_border_chars(_), do: get_border_chars(:none)

  @doc """
  Returns border chars in the 8-key format used by FocusRing and wrap_with_border.

  Keys: top_left, top, top_right, left, right, bottom_left, bottom, bottom_right
  """
  @spec get_border_chars_8key(border_style()) :: border_chars_8key()
  def get_border_chars_8key(style) do
    chars = get_border_chars(style)

    %{
      top_left: chars.top_left,
      top: chars.horizontal,
      top_right: chars.top_right,
      left: chars.vertical,
      right: chars.vertical,
      bottom_left: chars.bottom_left,
      bottom: chars.horizontal,
      bottom_right: chars.bottom_right
    }
  end

  @doc """
  Returns border characters, falling back to ASCII if the terminal
  does not support Unicode box-drawing characters.
  """
  @spec get_border_chars_adaptive(border_style()) :: border_chars()
  def get_border_chars_adaptive(style) do
    case unicode_supported?() do
      true -> get_border_chars(style)
      false -> get_border_chars(:ascii)
    end
  end

  defp unicode_supported? do
    case System.get_env("LANG") do
      nil -> false
      lang -> String.contains?(lang, "UTF") or String.contains?(lang, "utf")
    end
  end

  @doc """
  Renders box borders with proper styling.
  """
  @spec render_box_borders(
          integer(),
          integer(),
          pos_integer(),
          pos_integer(),
          border_chars(),
          map()
        ) :: [cell()]
  def render_box_borders(x, y, 1, 1, _border_chars, style) do
    {fg, bg, style_attrs} = extract_style_attributes(style)
    [{x, y, " ", fg, bg, style_attrs}]
  end

  def render_box_borders(x, y, width, height, border_chars, style) do
    {fg, _bg, style_attrs} = extract_style_attributes(style)

    fill_bg = Map.get(style, :bg) || Map.get(style, :background)

    fill_cells(x, y, width, height, fg, fill_bg) ++
      generate_border_cells(
        x,
        y,
        width,
        height,
        border_chars,
        fg,
        border_ring_bg(style, fill_bg),
        style_attrs
      )
  end

  # A cell is the smallest unit of paint, so a border glyph occupies a whole
  # cell and the background cannot stop halfway through it. The only question is
  # which side that cell belongs to -- exactly CSS `background-clip`:
  #
  #   :border_box (default)  background extends under the border: the border is
  #                          part of the box. A box that declares a background
  #                          is a filled panel, and its frame is that panel's
  #                          edge, not a separate thing floating beside it.
  #                          Leaving the ring unpainted lets whatever is behind
  #                          (a dimmed backdrop, the desktop) show through a
  #                          one-cell gap around the fill -- a seam that cannot
  #                          be tuned away once the colours differ.
  #
  #   :padding_box           background stops at the border's inner edge, so the
  #                          fill is inset by a cell and the outline sits on
  #                          whatever is behind it.
  #
  # A box with no background paints nothing either way -- border included -- so
  # an unfilled box stays fully transparent.
  #
  # An explicit :border_bg always wins over both.
  defp border_ring_bg(style, fill_bg) do
    case Map.get(style, :border_bg) do
      nil ->
        case Map.get(style, :background_clip, :border_box) do
          :padding_box -> nil
          _border_box -> fill_bg
        end

      border_bg ->
        border_bg
    end
  end

  # Interior only (inside the ring). Unpainted background paints nothing, so a
  # bordered box with no background stays fully transparent.
  defp fill_cells(_x, _y, _width, _height, _fg, nil), do: []

  defp fill_cells(x, y, width, height, fg, bg)
       when width > 2 and height > 2 do
    for i <- 1..(width - 2), j <- 1..(height - 2) do
      {x + i, y + j, " ", fg, bg, []}
    end
  end

  defp fill_cells(_x, _y, _width, _height, _fg, _bg), do: []

  defp extract_style_attributes(style) do
    {fg, bg} = resolve_colors(style)

    border_type =
      case Map.get(style, :border_style, :single) do
        %{type: type} -> type
        type when is_atom(type) -> type
        _ -> :single
      end

    style_attrs =
      case border_type do
        :none -> []
        _ -> [border_type]
      end

    {fg, bg, style_attrs}
  end

  defp generate_border_cells(
         x,
         y,
         width,
         height,
         border_chars,
         fg,
         bg,
         style_attrs
       ) do
    position = %{x: x, y: y, width: width, height: height}

    for i <- 0..(width - 1),
        j <- 0..(height - 1),
        i == 0 or i == width - 1 or j == 0 or j == height - 1 do
      get_border_cell(i, j, position, border_chars, fg, bg, style_attrs)
    end
  end

  defp get_border_cell(
         i,
         j,
         %{x: x, y: y, width: width, height: height},
         border_chars,
         fg,
         bg,
         style_attrs
       ) do
    {char, cell_x, cell_y} =
      get_border_char_and_position(i, j, x, y, width, height, border_chars)

    {cell_x, cell_y, char, fg, bg, style_attrs}
  end

  defp get_border_char_and_position(i, j, x, y, width, height, border_chars) do
    char = get_border_char(i, j, width, height, border_chars)
    {char_x, char_y} = get_border_position(i, j, x, y, width, height)
    {char, char_x, char_y}
  end

  defp get_border_char(i, j, width, height, border_chars) do
    case {i, j, width, height} do
      {0, 0, _, _} ->
        border_chars.top_left

      {i, 0, width, _} when i == width - 1 ->
        border_chars.top_right

      {0, j, _, height} when j == height - 1 ->
        border_chars.bottom_left

      {i, j, width, height} when i == width - 1 and j == height - 1 ->
        border_chars.bottom_right

      {_, j, _, height} when j == 0 or j == height - 1 ->
        border_chars.horizontal

      _ ->
        border_chars.vertical
    end
  end

  defp get_border_position(i, j, x, y, width, height) do
    char_x = get_border_x_position(i, x, width)
    char_y = get_border_y_position(j, y, height)
    {char_x, char_y}
  end

  defp get_border_x_position(i, x, width) when i == width - 1, do: x + width - 1
  defp get_border_x_position(i, x, _width), do: x + i

  defp get_border_y_position(j, y, height) when j == height - 1,
    do: y + height - 1

  defp get_border_y_position(j, y, _height), do: y + j

  @doc """
  Renders horizontal line.
  """
  @spec render_horizontal_line(
          integer(),
          integer(),
          pos_integer(),
          String.t(),
          map(),
          term()
        ) :: [cell()]
  def render_horizontal_line(x, y, width, char, style, _theme) do
    {fg, bg} = resolve_colors(style)

    for i <- 1..(width - 2) do
      {x + i, y, char, fg, bg, []}
    end
  end

  @doc """
  Renders vertical line.
  """
  @spec render_vertical_line(
          integer(),
          integer(),
          pos_integer(),
          String.t(),
          map(),
          term()
        ) :: [cell()]
  def render_vertical_line(x, y, height, char, style, _theme) do
    {fg, bg} = resolve_colors(style)

    for i <- 1..(height - 2) do
      {x, y + i, char, fg, bg, []}
    end
  end

  @doc """
  Renders empty box with no borders.
  """
  @spec render_empty_box(
          integer(),
          integer(),
          pos_integer(),
          pos_integer(),
          map()
        ) :: [cell()]
  def render_empty_box(x, y, width, height, style) do
    {fg, bg} = resolve_colors(style)

    for i <- 0..(width - 1), j <- 0..(height - 1) do
      {x + i, y + j, " ", fg, bg, []}
    end
  end

  defp resolve_colors(style) do
    fg =
      Map.get(style, :border_fg) || Map.get(style, :fg) ||
        Map.get(style, :foreground, :white)

    # nil, not :black -- an unpainted background must stay unpainted. The
    # renderer emits no SGR for a nil background, so the cell keeps the
    # terminal's default: on a transparent terminal it stays transparent.
    # Defaulting to :black emitted \e[40m, an opaque black cell that merely
    # *looked* right on an opaque black terminal.
    bg =
      Map.get(style, :border_bg) || Map.get(style, :bg) ||
        Map.get(style, :background)

    {fg, bg}
  end
end
