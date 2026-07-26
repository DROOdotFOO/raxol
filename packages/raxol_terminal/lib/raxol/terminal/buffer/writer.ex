defmodule Raxol.Terminal.Buffer.Writer do
  @moduledoc """
  Handles writing characters and strings to the Raxol.Terminal.ScreenBuffer.
  Responsible for character width, bidirectional text segmentation, and cell creation.
  """

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Cell
  alias Raxol.Terminal.ScreenBuffer

  @doc """
  Writes a character to the buffer at the specified position.
  Handles wide characters by taking up two cells when necessary.
  Accepts an optional style to apply to the cell.
  """
  @dialyzer {:nowarn_function, write_char: 5}
  @spec write_char(
          ScreenBuffer.t() | map(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          TextFormatting.text_style() | nil
        ) :: ScreenBuffer.t() | map()
  def write_char(buffer, x, y, char, style \\ nil)
      when x >= 0 and y >= 0 and is_map(buffer) do
    case within_bounds?(y, x, buffer.height, buffer.width) do
      true ->
        # Whole grapheme, not its first codepoint -- see `memoized_width/2`.
        width = Raxol.Terminal.CharacterHandling.get_char_width(char)
        cell_style = create_cell_style(style)
        log_char_write(char, x, y, cell_style)
        cells = update_cells(buffer, x, y, char, cell_style, width)
        %{buffer | cells: cells}

      false ->
        buffer
    end
  end

  @doc """
  Creates a cell style by merging the provided style with default formatting.

  ## Parameters

  * `style` - The style to merge with default formatting, or nil for default style

  ## Returns

  A map containing the merged text formatting style.

  ## Examples

      iex> Writer.create_cell_style(%{fg: :red})
      %{fg: :red, bg: :default, bold: false, ...}
  """
  @spec create_cell_style(TextFormatting.text_style() | nil) ::
          TextFormatting.t()
  def create_cell_style(nil), do: TextFormatting.new()

  def create_cell_style(style) when is_map(style) do
    style =
      case is_struct(style) do
        true -> Map.from_struct(style)
        false -> style
      end
      |> Map.new(fn {k, v} ->
        case k do
          :fg -> {:foreground, v}
          :bg -> {:background, v}
          _ -> {k, v}
        end
      end)

    Map.merge(TextFormatting.new(), style)
  end

  def create_cell_style(_), do: TextFormatting.new()

  @doc """
  Logs character write operations for debugging purposes.

  ## Parameters

  * `char` - The character being written
  * `x` - The x-coordinate where the character is being written
  * `y` - The y-coordinate where the character is being written
  * `cell_style` - The style being applied to the cell

  ## Returns

  :ok

  ## Examples

      iex> Writer.log_char_write("A", 0, 0, %{fg: :red})
      :ok
  """
  @spec log_char_write(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          TextFormatting.text_style()
        ) :: :ok
  def log_char_write(_char, _x, _y, _cell_style) do
    Raxol.Core.Runtime.Log.debug(
      # {char}" at {#{x}, #{y}} with style: #{inspect(cell_style)}"
      "[Buffer.Writer] Writing char "
    )
  end

  @doc """
  Updates cells in the buffer at the specified position.

  ## Parameters

  * `buffer` - The screen buffer to update
  * `x` - The x-coordinate to update
  * `y` - The y-coordinate to update
  * `char` - The character to write
  * `cell_style` - The style to apply
  * `width` - The width of the character (1 or 2 for wide characters)

  ## Returns

  The updated list of cells.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> Writer.update_cells(buffer, 0, 0, "A", %{fg: :red}, 1)
      [%Cell{char: "A", style: %{fg: :red}}, ...]
  """
  @spec update_cells(
          ScreenBuffer.t() | map(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          TextFormatting.text_style(),
          1..2
        ) :: list(list(Cell.t()))
  def update_cells(buffer, x, y, char, cell_style, width) do
    List.update_at(
      buffer.cells,
      y,
      &update_row(&1, x, char, cell_style, width, buffer.width)
    )
  end

  @doc """
  Updates a row in the buffer at the specified position.

  ## Parameters

  * `row` - The row to update
  * `x` - The x-coordinate to update
  * `char` - The character to write
  * `cell_style` - The style to apply
  * `width` - The width of the character (1 or 2 for wide characters)
  * `buffer_width` - The total width of the buffer

  ## Returns

  The updated row of cells.

  ## Examples

      iex> row = List.duplicate(Cell.new(), 80)
      iex> Writer.update_row(row, 0, "A", %{fg: :red}, 1, 80)
      [%Cell{char: "A", style: %{fg: :red}}, ...]
  """
  @spec update_row(
          list(Cell.t()),
          non_neg_integer(),
          String.t(),
          TextFormatting.text_style(),
          1..2,
          non_neg_integer()
        ) :: list(Cell.t())
  def update_row(row, x, char, cell_style, width, buffer_width) do
    new_cell = Cell.new(char, cell_style)
    # Same half-of-a-wide-pair cleanup `fill_cells/3` does -- the two paths
    # are documented to produce identical buffers.
    row = clear_wide_neighbour_in_row(row, x, width, buffer_width)

    case {width == 2, x + 1 < buffer_width} do
      {true, true} ->
        row
        |> List.update_at(x, fn _ -> new_cell end)
        |> List.update_at(x + 1, fn _ ->
          Cell.new_wide_placeholder(cell_style)
        end)

      # A wide character in the LAST column has nowhere to put its second
      # half. Writing the glyph anyway made the terminal draw two columns
      # into a one-column space, so the row painted one column wider than
      # the buffer and shoved whatever framed it out of alignment. A real
      # terminal never half-places a wide glyph: the cell is left blank
      # (the character is dropped here rather than wrapped, because this
      # function writes one cell at an explicit coordinate and has no
      # authority to move to the next row).
      {true, false} ->
        List.update_at(row, x, fn _ -> Cell.new(" ", cell_style) end)

      _ ->
        List.update_at(row, x, fn _ -> new_cell end)
    end
  end

  # List-based twin of `clear_wide_neighbour/5` (see its comment for why
  # both halves of a wide pair must die together).
  defp clear_wide_neighbour_in_row(row, x, width, buffer_width) do
    row
    |> clear_lead_in_row(x)
    |> clear_placeholder_in_row(x, buffer_width)
    |> clear_neighbour_lead_in_row(x, width, buffer_width)
  end

  defp clear_lead_in_row(row, x) when x > 0 do
    case wide_placeholder?(Enum.at(row, x)) do
      true -> List.update_at(row, x - 1, &Cell.new(" ", &1.style))
      false -> row
    end
  end

  defp clear_lead_in_row(row, _x), do: row

  defp clear_placeholder_in_row(row, x, buffer_width)
       when x + 1 < buffer_width do
    case wide_placeholder?(Enum.at(row, x + 1)) do
      true -> List.update_at(row, x + 1, &Cell.new(" ", &1.style))
      false -> row
    end
  end

  defp clear_placeholder_in_row(row, _x, _buffer_width), do: row

  # A WIDE write's own placeholder lands at `x + 1` -- which may currently
  # be serving as a DIFFERENT pair's LEAD (not its placeholder; that case
  # is `clear_placeholder_in_row/3` above, keyed off whether `x` itself
  # used to be a lead). If `x + 1` is a lead (i.e. `x + 2` is currently
  # flagged as a placeholder), that neighbour is about to be destroyed by
  # our own placeholder overwriting its lead -- clear its now-orphaned
  # placeholder at `x + 2` too, or the row paints one column too narrow
  # (see `clear_wide_neighbour/5`'s comment for the full write-up). Only
  # reachable for a wide write: a narrow write never touches `x + 1`, so
  # it can never disturb whatever pair `x + 1` belongs to.
  defp clear_neighbour_lead_in_row(row, x, 2, buffer_width),
    do: clear_placeholder_in_row(row, x + 1, buffer_width)

  defp clear_neighbour_lead_in_row(row, _x, _width, _buffer_width), do: row

  @typedoc """
  One bulk write: `{x, y, char, style}` with the same per-cell semantics
  as `write_char/5`.
  """
  @type cell_write ::
          {non_neg_integer(), non_neg_integer(), String.t() | nil,
           TextFormatting.text_style() | map() | nil}

  @doc """
  Bulk-writes a list of cells into the buffer in one pass per touched row.

  `cells` are applied IN LIST ORDER and the result is exactly the buffer
  that folding `write_char/5` over the list produces -- overwrites,
  wide-char placeholders, and bounds handling included -- at O(row)
  instead of O(cells x row) cost. Rows the list does not touch keep
  their original cell terms.

  `style_resolver` (optional) is invoked per in-bounds write with the
  cell's raw style and the cell currently at the target position --
  including cells written earlier in the same batch, matching the
  sequential fold where every write sees the buffer its predecessors
  built. Its return value is the style used for the write. Out-of-bounds
  writes are skipped without consulting the resolver (the sequential
  fold resolved and then discarded; resolution is pure, so skipping is
  unobservable).

  Two per-cell allocation sources of the sequential fold are shared
  here: cells with equal resolved styles share one merged style term
  (`create_cell_style/1` runs once per distinct style), and character
  widths are memoized per distinct character.
  """
  @spec fill_cells(
          ScreenBuffer.t() | map(),
          [cell_write()],
          (TextFormatting.text_style() | map() | nil, Cell.t() ->
             TextFormatting.text_style() | map() | nil)
          | nil
        ) :: ScreenBuffer.t() | map()
  def fill_cells(buffer, cells, style_resolver \\ nil)

  def fill_cells(buffer, [], _style_resolver) when is_map(buffer), do: buffer

  def fill_cells(buffer, cells, style_resolver)
      when is_map(buffer) and is_list(cells) do
    by_row =
      Enum.group_by(cells, fn
        {_x, y, _char, _style} when is_integer(y) and y >= 0 ->
          y

        # A negative / non-integer / malformed y is an extreme out-of-bounds
        # write: bucket it under a sentinel key the row scan never looks up,
        # so one bad coordinate is skipped like any other out-of-bounds cell
        # instead of raising FunctionClauseError and aborting the whole frame.
        _ ->
          :__out_of_bounds__
      end)

    height = buffer.height
    width = buffer.width

    {new_grid, _memo} =
      Enum.map_reduce(buffer.cells, {0, %{}}, fn row, {y, memo} ->
        case by_row do
          %{^y => row_cells} when y < height ->
            {new_row, memo} =
              fill_row(row, row_cells, width, style_resolver, memo)

            {new_row, {y + 1, memo}}

          _ ->
            {row, {y + 1, memo}}
        end
      end)

    %{buffer | cells: new_grid}
  end

  # One row: fold the row's writes (in input order) into a map keyed by x,
  # then materialize the row list in a single pass. The map IS the
  # interleaved buffer state `write_char` folds through -- a later write
  # sees (and overwrites) earlier writes, and the resolver reads it.
  defp fill_row(row, row_cells, width, style_resolver, memo) do
    original = List.to_tuple(row)

    {written, memo} =
      Enum.reduce(row_cells, {%{}, memo}, fn
        {x, _y, char, style}, {written, memo}
        when is_integer(x) and x >= 0 ->
          case x < width do
            true ->
              write_into(
                written,
                memo,
                original,
                x,
                char,
                style,
                width,
                style_resolver
              )

            false ->
              {written, memo}
          end

        # Negative / non-integer / malformed x: skip this cell (same as an
        # out-of-bounds write) rather than crashing the whole row's fold.
        _cell, {written, memo} ->
          {written, memo}
      end)

    case map_size(written) do
      0 ->
        {row, memo}

      _ ->
        {materialize_row(tuple_size(original) - 1, original, written, []), memo}
    end
  end

  defp write_into(
         written,
         memo,
         original,
         x,
         char,
         style,
         width,
         style_resolver
       ) do
    style =
      resolve_style(style_resolver, style, current_cell(written, original, x))

    {cell_style, memo} = memoized_style(style, memo)
    {char_width, memo} = memoized_width(char, memo)

    # Clearing runs for EVERY write, including the dropped-glyph branch --
    # `update_row/6` clears unconditionally too, and `fill_cells/3` is
    # documented to produce exactly the buffer that folding `write_char/5`
    # produces. Skipping it here made the two paths disagree whenever a
    # last-column wide write landed on half of an existing wide pair.
    written = clear_wide_neighbour(written, original, x, char_width, width)

    case {char_width == 2, x + 1 < width} do
      # A wide glyph with no room for its placeholder is dropped, not
      # half-placed -- see `update_row/6` for the reasoning.
      {true, false} ->
        {Map.put(written, x, Cell.new(" ", cell_style)), memo}

      _ ->
        write_glyph(written, memo, x, char, cell_style, char_width, width)
    end
  end

  defp write_glyph(written, memo, x, char, cell_style, char_width, width) do
    written = Map.put(written, x, Cell.new(char, cell_style))

    case char_width == 2 and x + 1 < width do
      true ->
        {Map.put(written, x + 1, Cell.new_wide_placeholder(cell_style)), memo}

      false ->
        {written, memo}
    end
  end

  defp current_cell(written, original, x) do
    case written do
      %{^x => cell} -> cell
      _ -> elem(original, x)
    end
  end

  # A wide character owns TWO columns: its glyph and the `wide_placeholder`
  # after it. Writing over EITHER half must clear the other, or the pair is
  # left half-alive and the row no longer paints its own width:
  #
  #   * overwrite the placeholder -> the lead glyph is orphaned but still
  #     drawn, and still two columns wide, so the row paints one column
  #     TOO WIDE (`日本` then "x" at the placeholder painted `日x本`).
  #   * overwrite the lead glyph with a narrow one -> the placeholder is
  #     orphaned, and since the renderer drops placeholders the row paints
  #     one column TOO NARROW.
  #
  # A THIRD case follows the same rule but at the NEIGHBOUR one column
  # further out: when THIS write is itself wide, its own placeholder lands
  # at `x + 1` -- which may currently be a DIFFERENT pair's lead glyph
  # (e.g. `日本` then a wide `月` at column 1: `月`'s placeholder overwrites
  # `本`'s lead at column 2). Overwriting that lead with a mere placeholder
  # orphans `本`'s OWN placeholder at column 3 exactly as the second case
  # above does, and it is invisible to `clear_orphaned_lead/placeholder`
  # above (both only look at column `x` itself, never `x + 1`) -- so the
  # row painted one column TOO NARROW again, just one column further
  # right. Only reachable for a wide write: a narrow write never touches
  # `x + 1`, so it can never disturb whatever pair `x + 1` belongs to.
  #
  # All three are cleared to a blank, which is what a terminal does when a
  # write lands inside a wide character.
  defp clear_wide_neighbour(written, original, x, char_width, width) do
    written
    |> clear_orphaned_lead(original, x)
    |> clear_orphaned_placeholder(original, x, width)
    |> clear_neighbour_lead(original, x, char_width, width)
  end

  defp clear_orphaned_lead(written, original, x) when x > 0 do
    case wide_placeholder?(current_cell(written, original, x)) do
      true -> Map.put(written, x - 1, blank_like(written, original, x - 1))
      false -> written
    end
  end

  defp clear_orphaned_lead(written, _original, _x), do: written

  defp clear_orphaned_placeholder(written, original, x, width)
       when x + 1 < width do
    case wide_placeholder?(current_cell(written, original, x + 1)) do
      true -> Map.put(written, x + 1, blank_like(written, original, x + 1))
      false -> written
    end
  end

  defp clear_orphaned_placeholder(written, _original, _x, _width), do: written

  defp clear_neighbour_lead(written, original, x, 2, width),
    do: clear_orphaned_placeholder(written, original, x + 1, width)

  defp clear_neighbour_lead(written, _original, _x, _char_width, _width),
    do: written

  defp wide_placeholder?(%{wide_placeholder: true}), do: true
  defp wide_placeholder?(_cell), do: false

  # Blanks a cell while keeping its style, so clearing half of a wide pair
  # does not punch a hole through a painted background.
  defp blank_like(written, original, x) do
    Cell.new(" ", current_cell(written, original, x).style)
  end

  defp resolve_style(nil, style, _current), do: style

  defp resolve_style(style_resolver, style, current),
    do: style_resolver.(style, current)

  defp memoized_style(style, memo) do
    key = {:style, style}

    case memo do
      %{^key => cell_style} ->
        {cell_style, memo}

      _ ->
        cell_style = create_cell_style(style)
        {cell_style, Map.put(memo, key, cell_style)}
    end
  end

  defp memoized_width(char, memo) do
    key = {:width, char}

    case memo do
      %{^key => char_width} ->
        {char_width, memo}

      _ ->
        # The whole GRAPHEME, not its first codepoint. Width is not always a
        # property of the leading codepoint: a flag is a pair of regional
        # indicators that is two columns wide, while each indicator alone is
        # one. Reducing to `hd/1` here asked an unanswerable question and got
        # 1, so no wide placeholder was reserved and the flag's second column
        # was painted over by the next character.
        char_width = Raxol.Terminal.CharacterHandling.get_char_width(char)
        {char_width, Map.put(memo, key, char_width)}
    end
  end

  defp materialize_row(i, _original, _written, acc) when i < 0, do: acc

  defp materialize_row(i, original, written, acc) do
    cell =
      case written do
        %{^i => cell} -> cell
        _ -> elem(original, i)
      end

    materialize_row(i - 1, original, written, [cell | acc])
  end

  @doc """
  Writes a string to the buffer at the specified position.
  Handles wide characters and bidirectional text.
  """
  @spec write_string(
          ScreenBuffer.t() | map(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          TextFormatting.text_style() | nil
        ) :: ScreenBuffer.t() | map()
  def write_string(buffer, x, y, string, style \\ nil)
      when x >= 0 and y >= 0 and is_map(buffer) do
    case within_bounds?(y, x, buffer.height, buffer.width) do
      true ->
        segments = Raxol.Terminal.CharacterHandling.process_bidi_text(string)

        Enum.reduce(segments, {buffer, x}, fn {_type, segment}, {acc_buffer, acc_x} ->
          {new_buffer, new_x} =
            write_segment(acc_buffer, acc_x, y, segment, style)

          {new_buffer, new_x}
        end)
        |> elem(0)

      false ->
        buffer
    end
  end

  @doc """
  Writes a segment of text to the buffer.

  ## Parameters

  * `buffer` - The screen buffer to write to
  * `x` - The x-coordinate to start writing at
  * `y` - The y-coordinate to write at
  * `segment` - The text segment to write

  ## Returns

  A tuple containing the updated buffer and the new x-coordinate.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> {new_buffer, new_x} = Writer.write_segment(buffer, 0, 0, "Hello")
      iex> new_x
      5
  """
  @spec write_segment(
          ScreenBuffer.t() | map(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          TextFormatting.text_style() | nil
        ) ::
          {ScreenBuffer.t() | map(), non_neg_integer()}
  def write_segment(buffer, x, y, segment, style \\ nil) do
    Enum.reduce(String.graphemes(segment), {buffer, x}, fn char, {acc_buffer, acc_x} ->
      # Whole grapheme, not its first codepoint -- see `memoized_width/2`.
      width = Raxol.Terminal.CharacterHandling.get_char_width(char)
      {write_char(acc_buffer, acc_x, y, char, style), acc_x + width}
    end)
  end

  defp within_bounds?(y, x, height, width) do
    y < height and x < width
  end
end
