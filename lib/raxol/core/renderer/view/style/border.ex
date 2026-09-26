defmodule Raxol.Core.Renderer.View.Style.Border do
  @moduledoc """
  Handles border rendering for the Raxol view system.
  Provides various border styles and rendering functionality.
  """

  alias Raxol.Core.Renderer.View.Types

  @doc """
  Creates a border around a view.

  ## Options
    * `:style` - Border style (:single, :double, :rounded, :bold, :dashed,
      :block, :simple); a style with no glyph set of its own draws as
      :single
    * `:padding` - Space between the border and the view (default 0)
    * `:title` - Optional title to display in the border
    * `:fg` - Foreground color
    * `:bg` - Background color

  ## Examples

      Border.wrap(view, style: :single)
      Border.wrap(view, style: :double, title: "Title")
  """
  def wrap(view, opts \\ []) do
    border_type = Keyword.get(opts, :border, Keyword.get(opts, :style, :single))

    # `Borders.block_border/2` and `simple_border/2` pass :block and :simple
    valid_styles = [
      :single,
      :double,
      :rounded,
      :bold,
      :dashed,
      :block,
      :simple,
      :none
    ]

    case border_type in valid_styles do
      false ->
        raise ArgumentError, "Invalid border style: #{inspect(border_type)}"

      true ->
        :ok
    end

    title = Keyword.get(opts, :title)
    padding = Keyword.get(opts, :padding, 0)
    fg = Keyword.get(opts, :fg)
    bg = Keyword.get(opts, :bg)

    %{
      type: :border,
      children: [view],
      border: border_type,
      padding: padding,
      title: title,
      fg: fg,
      bg: bg
    }
  end

  @doc """
  Renders a border around a view with the given style and dimensions.
  """
  def render_border(view, style, {width, height}) do
    chars = Types.border_chars()[style]
    title = view[:title]

    # Calculate title position and padding
    title_width = if title, do: String.length(title), else: 0
    title_padding = if title, do: 2, else: 0

    # Build the border
    top = build_top_border(chars, width, title, title_width, title_padding)
    middle = build_middle_border(chars, width, height - 2)
    bottom = build_bottom_border(chars, width)

    [top | middle] ++ [bottom]
  end

  @spec build_top_border(
          any(),
          String.t() | integer(),
          any(),
          String.t() | integer(),
          any()
        ) :: any()
  defp build_top_border(chars, width, nil, _title_width, _title_padding) do
    chars.top_left <>
      String.duplicate(chars.horizontal, width - 2) <>
      chars.top_right
  end

  @spec build_top_border(
          any(),
          String.t() | integer(),
          any(),
          String.t() | integer(),
          any()
        ) :: any()
  defp build_top_border(chars, width, title, title_width, title_padding) do
    left_width = div(width - title_width - title_padding, 2)
    right_width = width - left_width - title_width - title_padding

    chars.top_left <>
      String.duplicate(chars.horizontal, left_width) <>
      " #{title} " <>
      String.duplicate(chars.horizontal, right_width) <>
      chars.top_right
  end

  @spec build_middle_border(any(), String.t() | integer(), pos_integer()) ::
          any()
  defp build_middle_border(chars, width, height) do
    line = chars.vertical <> String.duplicate(" ", width - 2) <> chars.vertical
    List.duplicate(line, height)
  end

  defp build_bottom_border(chars, width) do
    chars.bottom_left <>
      String.duplicate(chars.horizontal, width - 2) <>
      chars.bottom_right
  end
end
