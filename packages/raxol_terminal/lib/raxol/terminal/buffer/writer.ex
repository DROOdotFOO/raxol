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
        codepoint = hd(String.to_charlist(char))
        width = Raxol.Terminal.CharacterHandling.get_char_width(codepoint)
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

    case {width == 2, x + 1 < buffer_width} do
      {true, true} ->
        row
        |> List.update_at(x, fn _ -> new_cell end)
        |> List.update_at(x + 1, fn _ ->
          Cell.new_wide_placeholder(cell_style)
        end)

      _ ->
        List.update_at(row, x, fn _ -> new_cell end)
    end
  end

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
      Enum.group_by(cells, fn {_x, y, _char, _style}
                              when is_integer(y) and y >= 0 ->
        y
      end)

    height = buffer.height
    width = buffer.width

    {new_grid, _memo} =
      Enum.map_reduce(buffer.cells, {0, %{}}, fn row, {y, memo} ->
        case by_row do
          %{^y => row_cells} when y < height ->
            {new_row, memo} = fill_row(row, row_cells, width, style_resolver, memo)
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
      Enum.reduce(row_cells, {%{}, memo}, fn {x, _y, char, style}, {written, memo}
                                             when is_integer(x) and x >= 0 ->
        case x < width do
          true ->
            write_into(written, memo, original, x, char, style, width, style_resolver)

          false ->
            {written, memo}
        end
      end)

    case map_size(written) do
      0 -> {row, memo}
      _ -> {materialize_row(tuple_size(original) - 1, original, written, []), memo}
    end
  end

  defp write_into(written, memo, original, x, char, style, width, style_resolver) do
    style = resolve_style(style_resolver, style, current_cell(written, original, x))
    {cell_style, memo} = memoized_style(style, memo)
    {char_width, memo} = memoized_width(char, memo)

    written = Map.put(written, x, Cell.new(char, cell_style))

    case char_width == 2 and x + 1 < width do
      true -> {Map.put(written, x + 1, Cell.new_wide_placeholder(cell_style)), memo}
      false -> {written, memo}
    end
  end

  defp current_cell(written, original, x) do
    case written do
      %{^x => cell} -> cell
      _ -> elem(original, x)
    end
  end

  defp resolve_style(nil, style, _current), do: style
  defp resolve_style(style_resolver, style, current), do: style_resolver.(style, current)

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
        codepoint = hd(String.to_charlist(char))
        char_width = Raxol.Terminal.CharacterHandling.get_char_width(codepoint)
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
      codepoint = hd(String.to_charlist(char))
      width = Raxol.Terminal.CharacterHandling.get_char_width(codepoint)
      {write_char(acc_buffer, acc_x, y, char, style), acc_x + width}
    end)
  end

  defp within_bounds?(y, x, height, width) do
    y < height and x < width
  end
end
