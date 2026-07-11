defmodule Raxol.UI.Layout.MinContent do
  @moduledoc """
  Min-content inline (width) measurement — proposal Phase B (flex rework N8).

  The min-content width of an element is the smallest width it can occupy
  without losing content: the longest unbreakable segment for text, the
  declared width for fixed boxes, aggregates for containers.

  Pure and unwired: `FlexItem` resolution adopts this as the automatic
  minimum size (`min-width: auto`) in Phase B3. Until then nothing in the
  live path calls it. Fixes the L6 class: a full-width divider's min-content
  is 1 cell, so it stops inflating measured container widths and robbing
  fixed-width siblings during shrink.

  Widths via `Raxol.UI.TextMeasure` exclusively (CJK double-width).
  Unknown element types measure 0 (conservative: they impose no minimum).
  """

  alias Raxol.UI.TextMeasure

  @doc "Min-content width of an element, in cells."
  def width(element)

  def width(%{type: :text} = el), do: longest_segment(text_of(el))
  def width(%{type: :label} = el), do: longest_segment(text_of(el))

  def width(%{type: :divider}), do: 1
  def width(%{type: :spacer}), do: 0

  def width(%{type: :box} = box) do
    case explicit_width(box) do
      w when is_integer(w) and w >= 0 ->
        w

      _ ->
        children_min(children_of(box), :max) + box_overhead(box)
    end
  end

  def width(%{type: :flex} = flex) do
    case explicit_width(flex) do
      w when is_integer(w) and w >= 0 ->
        w

      _ ->
        children = children_of(flex)

        case direction_of(flex) do
          :row ->
            gap = gap_of(flex)
            children_min(children, :sum) + gap * max(0, length(children) - 1)

          :column ->
            children_min(children, :max)
        end
    end
  end

  def width(%{type: type} = el) when type in [:row, :column] do
    width(
      Map.put(el, :type, :flex)
      |> Map.put_new(:direction, container_direction(type))
    )
  end

  def width(%{type: :view} = el), do: children_min(children_of(el), :max)

  # Components that render a fixed-ish chrome around text
  def width(%{type: :button} = el),
    do: TextMeasure.display_width(text_of(el)) + 4

  def width(%{type: :checkbox} = el),
    do: TextMeasure.display_width(text_of(el)) + 4

  def width(_unknown), do: 0

  # -- helpers ----------------------------------------------------------------

  @doc """
  Longest unbreakable segment of a text, by display width.

  Break opportunities mirror TextLayout: spaces, after hyphens, and between
  CJK ideographs (each CJK grapheme is its own segment).
  """
  def longest_segment(nil), do: 0
  def longest_segment(""), do: 0

  def longest_segment(text) when is_binary(text) do
    text
    |> String.split(~r/[\s\x{200B}]+/u, trim: true)
    |> Enum.flat_map(&split_after_hyphens/1)
    |> Enum.flat_map(&split_cjk/1)
    |> Enum.map(&TextMeasure.display_width/1)
    |> Enum.max(fn -> 0 end)
  end

  defp split_after_hyphens(word) do
    word
    |> String.split(~r/(?<=-)/u, trim: true)
  end

  # CJK ideographs/kana are break opportunities between each other: a run of
  # CJK graphemes contributes single-grapheme segments (min-content 2 cells).
  defp split_cjk(segment) do
    segment
    |> String.graphemes()
    |> Enum.chunk_by(&cjk?/1)
    |> Enum.flat_map(fn
      [g | _] = run ->
        if cjk?(g), do: run, else: [Enum.join(run)]
    end)
  end

  defp cjk?(<<cp::utf8, _rest::binary>>) do
    cp in 0x1100..0x115F or cp in 0x2E80..0x9FFF or cp in 0xAC00..0xD7A3 or
      cp in 0xF900..0xFAFF or cp in 0xFF00..0xFF60 or cp in 0x20000..0x2FFFD
  end

  defp cjk?(_), do: false

  defp text_of(el), do: Map.get(el, :text) || Map.get(el, :content) || ""

  defp children_of(el) do
    case Map.get(el, :children) do
      nil -> []
      %{} = child -> [child]
      list when is_list(list) -> list
      other -> [other]
    end
  end

  defp children_min([], _), do: 0

  defp children_min(children, :max),
    do: children |> Enum.map(&width/1) |> Enum.max(fn -> 0 end)

  defp children_min(children, :sum),
    do: children |> Enum.map(&width/1) |> Enum.sum()

  defp explicit_width(el) do
    style = style_of(el)

    Map.get(el, :width) || Map.get(style, :width) ||
      case Map.get(el, :size) do
        {w, _h} -> w
        _ -> nil
      end
  end

  defp style_of(el) do
    case Map.get(el, :style) do
      s when is_map(s) -> s
      _ -> %{}
    end
  end

  defp box_overhead(box) do
    style = style_of(box)
    border = Map.get(box, :border) || Map.get(style, :border, :none)
    border_cells = if border in [:none, false, nil], do: 0, else: 2

    {_t, r, _b, l} =
      case Map.get(box, :padding) || Map.get(style, :padding, 0) do
        n when is_integer(n) -> {n, n, n, n}
        {h, v} -> {v, h, v, h}
        {t, r, b, l} -> {t, r, b, l}
        _ -> {0, 0, 0, 0}
      end

    border_cells + l + r
  end

  defp direction_of(flex) do
    Map.get(flex, :direction) ||
      flex |> Map.get(:attrs, %{}) |> Map.get(:flex_direction, :row)
  end

  defp gap_of(flex) do
    raw =
      Map.get(style_of(flex), :gap) || Map.get(flex, :gap) ||
        flex |> Map.get(:attrs, %{}) |> Map.get(:gap, 0)

    case raw do
      n when is_integer(n) and n >= 0 -> n
      %{column: c} when is_integer(c) -> c
      _ -> 0
    end
  end

  defp container_direction(:row), do: :row
  defp container_direction(:column), do: :column
end
