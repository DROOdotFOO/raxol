defmodule Raxol.UI.Components.Harness.LineDiff do
  @moduledoc """
  Line-based diff between two blocks of text.

  Computes the longest common subsequence (LCS) of lines via dynamic
  programming, then backtracks it into an ordered list of `:equal`,
  `:delete`, and `:insert` operations -- the shape a unified diff walks
  over. This is a plain LCS diff (not Myers): O(lines_old * lines_new)
  time and space, which is the right tradeoff for the file-edit-sized
  diffs a pre-apply confirmation UI renders (correctness over
  cleverness), not for diffing huge files.

  Used by `Raxol.UI.Components.Harness.DiffViewer`.
  """

  @type op ::
          {:equal, String.t()} | {:delete, String.t()} | {:insert, String.t()}

  @doc """
  Diffs two texts line-by-line, returning ops in old-then-new document order.

  Splits on `"\\n"`; a trailing newline on both sides produces a matching
  trailing empty-line pair (shown as context), not a spurious change. An
  empty string is treated as zero lines (not one blank line), so diffing
  against `""` reads as a whole-file add/remove.

  ## Examples

      iex> Raxol.UI.Components.Harness.LineDiff.diff("a\\nb\\nc", "a\\nx\\nc")
      [equal: "a", delete: "b", insert: "x", equal: "c"]

      iex> Raxol.UI.Components.Harness.LineDiff.diff("", "a\\nb")
      [insert: "a", insert: "b"]
  """
  @spec diff(String.t(), String.t()) :: [op()]
  def diff(old_text, new_text)
      when is_binary(old_text) and is_binary(new_text) do
    old_arr = old_text |> lines() |> List.to_tuple()
    new_arr = new_text |> lines() |> List.to_tuple()
    old_count = tuple_size(old_arr)
    new_count = tuple_size(new_arr)

    lengths = lcs_table(old_arr, new_arr, old_count, new_count)
    backtrack(lengths, old_arr, new_arr, old_count, new_count, [])
  end

  defp lines(""), do: []
  defp lines(text), do: String.split(text, "\n")

  # `lengths` is a tuple-of-tuples: `elem(elem(lengths, i), j)` is the LCS
  # length of old[0..i) and new[0..j). Built row by row so every cell only
  # ever reads already-built neighbours (the previous row, and this row's
  # own previous column).
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
    old_line = elem(old_arr, i - 1)
    new_line = elem(new_arr, j - 1)

    cond do
      old_line == new_line ->
        op = {:equal, old_line}
        backtrack(lengths, old_arr, new_arr, i - 1, j - 1, [op | acc])

      cell(lengths, i, j - 1) >= cell(lengths, i - 1, j) ->
        op = {:insert, new_line}
        backtrack(lengths, old_arr, new_arr, i, j - 1, [op | acc])

      true ->
        op = {:delete, old_line}
        backtrack(lengths, old_arr, new_arr, i - 1, j, [op | acc])
    end
  end

  defp cell(lengths, i, j), do: lengths |> elem(i) |> elem(j)
end
