defmodule Raxol.UI.Components.Harness.Composer.WrapMap do
  @moduledoc """
  One-way logical->visual projection for the composer draft.

  The composer's editing truth is the LOGICAL draft (`mli.value`) plus a
  logical cursor (`{logical_row, grapheme_col}` against the `"\\n"`-split
  lines). Everything visual -- the wrapped display rows, the cursor's
  visual row/column, the terminal-cursor park -- is derived from that
  truth through this map, and NOTHING derived here ever feeds back into
  an edit operation. That one-way law is the fix for the leading-space
  corruption class: the display wrapper used to double as the edit
  substrate, so its trimming (leading/trailing whitespace) silently
  rewrote the draft on every rewrap.

  ## Segments

  `build/3` splits the draft into logical lines and wraps each with
  `Raxol.UI.TextLayout.wrap(line, width, :pre_wrap)` -- the harness's
  content-preserving, display-width-aware splitter (the wrap-corpus
  suite pins its Unicode behavior). Each produced piece becomes one
  visual row, tagged with the logical row it came from and its exact
  grapheme offset into that logical line:

      %{text: "aaaa bbbb ", row: 0, start: 0}
      %{text: "cccc",       row: 0, start: 10}

  `:pre_wrap` preserves every grapheme EXCEPT a whitespace run dropped
  exactly at a wrap point (there is no monospace-grid "hang"), so
  `build/3` re-aligns each piece against the logical line to recover
  the true `start` offsets -- only whitespace can sit in the gaps.

  ## Projections

    * `to_visual/2` -- logical `{row, col}` -> `{visual_row, grapheme
      col within that row's text}`. A cursor sitting exactly on a wrap
      boundary projects to the START of the next visual row (standard
      soft-wrap affinity); a cursor inside a dropped-whitespace gap
      projects to the END of the row before it.
    * `cell_col/2` -- a visual position -> its display-cell column
      (`Raxol.UI.TextMeasure`, CJK/emoji double-width).
    * `to_logical/3` -- `{visual_row, goal cells}` -> the logical
      position of the widest grapheme prefix that fits the goal --
      the up/down goal-column rule.
  """

  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure

  @type segment :: %{
          text: String.t(),
          row: non_neg_integer(),
          start: non_neg_integer()
        }
  @type t :: %__MODULE__{segments: [segment()], width: pos_integer()}

  defstruct segments: [%{text: "", row: 0, start: 0}], width: 1

  @doc """
  Builds the projection map for `value` at `width`. `wrap_mode :none`
  maps each logical line to exactly one visual row (no soft wrap); any
  other mode wraps content-preservingly at `width` display cells.
  """
  @spec build(String.t(), integer(), :none | :char | :word) :: t()
  def build(value, width, wrap_mode) do
    segments =
      value
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, row} ->
        line_segments(line, row, width, wrap_mode)
      end)

    %__MODULE__{segments: segments, width: max(width, 1)}
  end

  @doc "The visual rows, in order -- the composer's display lines."
  @spec lines(t()) :: [String.t()]
  def lines(%__MODULE__{segments: segments}), do: Enum.map(segments, & &1.text)

  @doc "Number of visual rows."
  @spec row_count(t()) :: pos_integer()
  def row_count(%__MODULE__{segments: segments}), do: length(segments)

  @doc """
  Projects a logical cursor position to `{visual_row, grapheme_col}`.
  Out-of-range positions clamp to the nearest representable one.
  """
  @spec to_visual(t(), {integer(), integer()}) ::
          {non_neg_integer(), non_neg_integer()}
  def to_visual(%__MODULE__{segments: segments}, {lrow, lcol}) do
    indexed = Enum.with_index(segments)

    case Enum.filter(indexed, fn {seg, _} -> seg.row == lrow end) do
      [] ->
        {seg, vi} = List.last(indexed)
        {vi, String.length(seg.text)}

      row_segs ->
        place(row_segs, lcol)
    end
  end

  @doc """
  Display-cell column (0-based) of a visual position -- the width of the
  grapheme prefix before the cursor on that row.
  """
  @spec cell_col(t(), {non_neg_integer(), non_neg_integer()}) ::
          non_neg_integer()
  def cell_col(%__MODULE__{segments: segments}, {vrow, gcol}) do
    case Enum.at(segments, vrow) do
      nil -> 0
      seg -> TextMeasure.display_width(String.slice(seg.text, 0, gcol))
    end
  end

  @doc """
  Maps `{visual_row, goal display cells}` back to a logical position:
  the widest grapheme prefix of that row whose display width does not
  exceed the goal (a wide grapheme is never split). The visual row is
  clamped into range.
  """
  @spec to_logical(t(), integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def to_logical(%__MODULE__{segments: segments}, vrow, goal_cells) do
    vrow = vrow |> max(0) |> min(length(segments) - 1)
    seg = Enum.at(segments, vrow)
    {seg.row, seg.start + grapheme_fit(seg.text, goal_cells)}
  end

  # -- private ----------------------------------------------------------

  defp line_segments(line, row, width, wrap_mode)
       when wrap_mode == :none or width <= 0 do
    [%{text: line, row: row, start: 0}]
  end

  defp line_segments(line, row, width, _wrap_mode) do
    line
    |> TextLayout.wrap(width, :pre_wrap)
    |> align(line, row)
  end

  # Recovers each piece's grapheme offset into the logical line. Pieces
  # appear in order; only whitespace (a run dropped at a wrap point) can
  # separate one piece's end from the next piece's start.
  defp align(pieces, line, row) do
    {segments, _offset} =
      Enum.map_reduce(pieces, 0, fn piece, offset ->
        offset = skip_to_match(line, piece, offset)

        {%{text: piece, row: row, start: offset}, offset + String.length(piece)}
      end)

    segments
  end

  defp skip_to_match(line, piece, offset) do
    cond do
      piece == "" ->
        offset

      String.slice(line, offset, String.length(piece)) == piece ->
        offset

      whitespace?(String.slice(line, offset, 1)) ->
        skip_to_match(line, piece, offset + 1)

      true ->
        # Unreachable by :pre_wrap's contract (only whitespace is ever
        # dropped); accepting the offset keeps the map total.
        offset
    end
  end

  defp whitespace?(grapheme),
    do: grapheme != "" and String.trim(grapheme) == ""

  # Walks this logical row's segments in visual order.
  defp place([{seg, vi}], lcol) do
    gcol = lcol - seg.start
    {vi, gcol |> max(0) |> min(String.length(seg.text))}
  end

  defp place([{seg, vi} | [{next, _} | _] = rest], lcol) do
    seg_end = seg.start + String.length(seg.text)

    cond do
      # Strictly inside this segment (or before it -- clamp up).
      lcol < seg_end ->
        {vi, max(lcol - seg.start, 0)}

      # Inside a dropped-whitespace gap, or exactly at this segment's
      # end with a gap following: the position sits before the dropped
      # run -- show it at the end of this row.
      lcol < next.start ->
        {vi, String.length(seg.text)}

      # At or past the next segment's start: soft-wrap affinity puts a
      # boundary cursor at the START of the next visual row.
      true ->
        place(rest, lcol)
    end
  end

  # Widest grapheme prefix of `text` whose display width fits `cells`.
  defp grapheme_fit(text, cells) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, 0}, fn grapheme, {count, cells_used} ->
      used = cells_used + TextMeasure.display_width(grapheme)

      if used > cells do
        {:halt, {count, cells_used}}
      else
        {:cont, {count + 1, used}}
      end
    end)
    |> elem(0)
  end
end
