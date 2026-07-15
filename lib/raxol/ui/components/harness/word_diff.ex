defmodule Raxol.UI.Components.Harness.WordDiff do
  @moduledoc """
  Intra-line word diff for a paired deletion/addition line.

  Ports the intra-line model from
  `docs/proposals/in-flight/pierre-diffs-analysis.md` §1.3: for a paired
  change row (the i-th deletion of a changed hunk against its i-th
  addition -- purely positional, no similarity matching), tokenize both
  lines into words and whitespace runs, diff the token sequences (LCS),
  and collapse the changed token runs into `{char_start, char_length}`
  ranges per side. The `word-alt` join rule merges two changed spans
  separated by a single unchanged whitespace token into one span (e.g.
  `"red apple pie"` -> `"blue mango pie"` highlights `"red apple"` as one
  region, not two words with a highlighted gap between them).

  Pairing itself (which deletion goes with which addition) is the
  caller's job -- `Raxol.UI.Components.Harness.DiffViewer` does that at
  the change-block level. This module only diffs one already-paired pair
  of lines.

  Ranges are **grapheme offsets into the line text**, not display-width
  columns: they exist to slice a string (`String.slice/3`), and a cut
  position between two graphemes is correct regardless of how many
  terminal columns a wide grapheme occupies. Column math for layout
  (padding, gutter width, pane-fit) is a separate concern already handled
  via `Raxol.UI.TextMeasure` elsewhere in the diff viewer.
  """

  @type range :: {non_neg_integer(), pos_integer()}

  # Pierre's `maxLineDiffLength` (default 1000): above this, skip the
  # intra-line diff entirely and let the whole line render unemphasized.
  @max_line_length 1000

  @doc """
  Computes changed-word ranges for a paired deletion/addition line pair.

  Returns `{old_ranges, new_ranges}`. Either side is `[]` (no ranges) when
  the line has no word-level differences, or -- the guard -- when either
  line exceeds #{@max_line_length} characters.

  ## Examples

      iex> Raxol.UI.Components.Harness.WordDiff.word_ranges("foo bar", "baz bar")
      {[{0, 3}], [{0, 3}]}

      iex> Raxol.UI.Components.Harness.WordDiff.word_ranges("same", "same")
      {[], []}
  """
  @spec word_ranges(String.t(), String.t()) :: {[range()], [range()]}
  def word_ranges(old_line, new_line)
      when is_binary(old_line) and is_binary(new_line) do
    if String.length(old_line) > @max_line_length or
         String.length(new_line) > @max_line_length do
      {[], []}
    else
      ops = token_diff(tokenize(old_line), tokenize(new_line))

      {side_ranges(ops, :old), side_ranges(ops, :new)}
    end
  end

  defp tokenize(""), do: []

  defp tokenize(line) do
    ~r/\s+|\S+/u
    |> Regex.scan(line)
    |> Enum.map(&hd/1)
  end

  # -- Per-side segment classification + word-alt merge + range folding --

  defp side_ranges(ops, side) do
    ops
    |> side_segments(side)
    |> apply_word_alt()
    |> segments_to_ranges()
  end

  # Drops the tokens absent from this side (:insert on the old/:delete
  # side never existed there; :delete on the new/:insert side never
  # existed there) and classifies what remains.
  defp side_segments(ops, :old) do
    for {kind, token} <- ops, kind != :insert do
      {classify(kind), token}
    end
  end

  defp side_segments(ops, :new) do
    for {kind, token} <- ops, kind != :delete do
      {classify(kind), token}
    end
  end

  defp classify(:equal), do: :unchanged
  defp classify(_kind), do: :changed

  # `word-alt`: a lone unchanged token of length 1 (a single whitespace
  # char, in practice) flanked by changed tokens on both sides gets
  # absorbed into the changed run instead of leaving a one-token gap.
  defp apply_word_alt(segments) do
    arr = List.to_tuple(segments)
    n = tuple_size(arr)

    for i <- 0..(n - 1) do
      {cls, text} = elem(arr, i)

      if cls == :unchanged and String.length(text) == 1 and
           changed_at?(arr, i - 1) and changed_at?(arr, i + 1) do
        {:changed, text}
      else
        {cls, text}
      end
    end
  end

  defp changed_at?(arr, i) when i >= 0 and i < tuple_size(arr) do
    elem(arr, i) |> elem(0) == :changed
  end

  defp changed_at?(_arr, _i), do: false

  # Walks the (now word-alt-merged) segments left to right, coalescing
  # consecutive :changed segments into a single {start, length} range.
  defp segments_to_ranges(segments) do
    {ranges_rev, _offset, trailing} =
      Enum.reduce(segments, {[], 0, nil}, fn {cls, text},
                                             {ranges, offset, current} ->
        len = String.length(text)
        fold_segment(cls, len, offset, current, ranges)
      end)

    ranges = if trailing, do: [trailing | ranges_rev], else: ranges_rev
    Enum.reverse(ranges)
  end

  defp fold_segment(:changed, len, offset, nil, ranges),
    do: {ranges, offset + len, {offset, len}}

  defp fold_segment(:changed, len, offset, {start, cur_len}, ranges),
    do: {ranges, offset + len, {start, cur_len + len}}

  defp fold_segment(:unchanged, len, offset, nil, ranges),
    do: {ranges, offset + len, nil}

  defp fold_segment(:unchanged, len, offset, current, ranges),
    do: {[current | ranges], offset + len, nil}

  # -- Token-level LCS (same shape as LineDiff's line-level LCS, generic
  # over any list of terms compared by `==`) --

  defp token_diff(old_tokens, new_tokens) do
    old_arr = List.to_tuple(old_tokens)
    new_arr = List.to_tuple(new_tokens)
    old_count = tuple_size(old_arr)
    new_count = tuple_size(new_arr)

    lengths = lcs_table(old_arr, new_arr, old_count, new_count)
    backtrack(lengths, old_arr, new_arr, old_count, new_count, [])
  end

  defp lcs_table(old_arr, new_arr, old_count, new_count) do
    0..old_count
    |> Enum.reduce([], fn i, rows_acc ->
      [build_row(old_arr, new_arr, i, new_count, rows_acc) | rows_acc]
    end)
    |> Enum.reverse()
    |> List.to_tuple()
  end

  defp build_row(old_arr, new_arr, i, new_count, rows_acc) do
    prev_row = if i == 0, do: nil, else: hd(rows_acc)

    0..new_count
    |> Enum.reduce([], fn j, row_acc ->
      [cell_value(old_arr, new_arr, i, j, prev_row, row_acc) | row_acc]
    end)
    |> Enum.reverse()
    |> List.to_tuple()
  end

  defp cell_value(_old_arr, _new_arr, 0, _j, _prev_row, _row_acc), do: 0
  defp cell_value(_old_arr, _new_arr, _i, 0, _prev_row, _row_acc), do: 0

  defp cell_value(old_arr, new_arr, i, j, prev_row, row_acc) do
    if elem(old_arr, i - 1) == elem(new_arr, j - 1) do
      elem(prev_row, j - 1) + 1
    else
      max(elem(prev_row, j), hd(row_acc))
    end
  end

  defp backtrack(_lengths, _old_arr, _new_arr, 0, 0, acc), do: acc

  defp backtrack(lengths, old_arr, new_arr, i, 0, acc) when i > 0 do
    op = {:delete, elem(old_arr, i - 1)}
    backtrack(lengths, old_arr, new_arr, i - 1, 0, [op | acc])
  end

  defp backtrack(lengths, old_arr, new_arr, 0, j, acc) when j > 0 do
    op = {:insert, elem(new_arr, j - 1)}
    backtrack(lengths, old_arr, new_arr, 0, j - 1, [op | acc])
  end

  defp backtrack(lengths, old_arr, new_arr, i, j, acc) do
    old_token = elem(old_arr, i - 1)
    new_token = elem(new_arr, j - 1)

    cond do
      old_token == new_token ->
        op = {:equal, old_token}
        backtrack(lengths, old_arr, new_arr, i - 1, j - 1, [op | acc])

      cell(lengths, i, j - 1) >= cell(lengths, i - 1, j) ->
        op = {:insert, new_token}
        backtrack(lengths, old_arr, new_arr, i, j - 1, [op | acc])

      true ->
        op = {:delete, old_token}
        backtrack(lengths, old_arr, new_arr, i - 1, j, [op | acc])
    end
  end

  defp cell(lengths, i, j), do: lengths |> elem(i) |> elem(j)
end
