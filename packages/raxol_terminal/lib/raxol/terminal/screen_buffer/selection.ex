defmodule Raxol.Terminal.ScreenBuffer.Selection do
  @moduledoc """
  Text selection operations for the screen buffer.
  Handles selection creation, updates, text extraction, and clipboard operations.
  """

  alias Raxol.Terminal.Cell
  alias Raxol.Terminal.ScreenBuffer.Core
  alias Raxol.Terminal.ScreenBuffer.SharedOperations

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  @type selection ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | nil

  @doc """
  Starts a new selection at the specified position.
  """
  @spec start_selection(Core.t(), non_neg_integer(), non_neg_integer()) ::
          Core.t()
  def start_selection(buffer, x, y) do
    %{buffer | selection: {x, y, x, y}}
  end

  @doc """
  Extends the selection to the specified position.
  Starts a new selection if none exists.
  """
  @spec extend_selection(Core.t(), non_neg_integer(), non_neg_integer()) ::
          Core.t()
  def extend_selection(buffer, x, y) do
    case buffer.selection do
      {start_x, start_y, _, _} ->
        %{buffer | selection: {start_x, start_y, x, y}}

      nil ->
        start_selection(buffer, x, y)
    end
  end

  @doc """
  Clears the current selection.
  """
  @spec clear_selection(Core.t()) :: Core.t()
  def clear_selection(buffer) do
    %{buffer | selection: nil}
  end

  @doc """
  Gets the current selection boundaries, normalized so start <= end.
  """
  @spec get_selection(Core.t()) :: selection()
  def get_selection(buffer) do
    case buffer.selection do
      nil -> nil
      {x1, y1, x2, y2} -> SharedOperations.normalize_selection(x1, y1, x2, y2)
    end
  end

  @doc """
  Checks if there is an active selection.
  """
  @spec has_selection?(Core.t()) :: boolean()
  def has_selection?(buffer) do
    buffer.selection != nil
  end

  @doc """
  Checks if the specified position is within the current selection.
  """
  @spec selected?(Core.t(), integer(), integer()) :: boolean()
  def selected?(buffer, x, y) do
    case get_selection(buffer) do
      nil ->
        false

      {start_x, start_y, end_x, end_y} ->
        SharedOperations.position_in_selection?(
          x,
          y,
          start_x,
          start_y,
          end_x,
          end_y
        )
    end
  end

  @doc """
  Checks if a position is within the current selection.
  Delegates to `selected?/3`.
  """
  @spec position_in_selection?(Core.t(), integer(), integer()) :: boolean()
  def position_in_selection?(buffer, x, y), do: selected?(buffer, x, y)

  @doc """
  Gets the selected text as a string.
  """
  @spec get_selected_text(Core.t()) :: String.t()
  def get_selected_text(buffer) do
    case get_selection(buffer) do
      nil ->
        ""

      {start_x, start_y, end_x, end_y} ->
        extract_text_region(buffer, start_x, start_y, end_x, end_y)
    end
  end

  @doc """
  Gets the selected text as lines.
  """
  @spec get_selected_lines(Core.t()) :: [String.t()]
  def get_selected_lines(buffer) do
    case get_selection(buffer) do
      nil ->
        []

      {start_x, start_y, end_x, end_y} ->
        extract_lines_region(buffer, start_x, start_y, end_x, end_y)
    end
  end

  @doc """
  Selects an entire line.
  """
  @spec select_line(Core.t(), integer()) :: Core.t()
  def select_line(buffer, y) when y >= 0 and y < buffer.height do
    %{buffer | selection: {0, y, buffer.width - 1, y}}
  end

  def select_line(buffer, _y), do: buffer

  @doc """
  Selects multiple lines.
  """
  @spec select_lines(Core.t(), integer(), integer()) :: Core.t()
  def select_lines(buffer, start_y, end_y) do
    start_y = clamp_to_bounds(start_y, buffer.height)
    end_y = clamp_to_bounds(end_y, buffer.height)
    %{buffer | selection: {0, start_y, buffer.width - 1, end_y}}
  end

  @doc """
  Selects all content in the buffer.
  """
  @spec select_all(Core.t()) :: Core.t()
  def select_all(buffer) do
    %{buffer | selection: {0, 0, buffer.width - 1, buffer.height - 1}}
  end

  @doc """
  Selects a word at the given position.
  """
  @spec select_word(Core.t(), integer(), integer()) :: Core.t()
  def select_word(buffer, x, y) when x >= 0 and y >= 0 and y < buffer.height do
    line = Core.get_line(buffer, y)

    # Find word boundaries
    {start_x, end_x} = find_word_boundaries(line, x)

    %{buffer | selection: {start_x, y, end_x, y}}
  end

  def select_word(buffer, _x, _y), do: buffer

  @doc """
  Expands selection to word boundaries.
  """
  @spec expand_selection_to_word(Core.t()) :: Core.t()
  def expand_selection_to_word(buffer) do
    case buffer.selection do
      {x1, y1, x2, y2} ->
        line1 = Core.get_line(buffer, y1)
        line2 = Core.get_line(buffer, y2)

        {start_x, _} = find_word_boundaries(line1, x1)
        {_, end_x} = find_word_boundaries(line2, x2)

        %{buffer | selection: {start_x, y1, end_x, y2}}

      nil ->
        buffer
    end
  end

  # === Functions moved from main ScreenBuffer module ===

  @doc """
  Updates the selection endpoint. Returns buffer unchanged if no selection exists.
  Unlike `extend_selection/3`, does not start a new selection on nil.
  """
  @spec update_selection(Core.t(), non_neg_integer(), non_neg_integer()) ::
          Core.t()
  def update_selection(buffer, x, y) do
    case buffer.selection do
      {sx, sy, _, _} -> %{buffer | selection: {sx, sy, x, y}}
      nil -> buffer
    end
  end

  @spec get_selection_boundaries(Core.t()) ::
          {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}}
          | nil
  def get_selection_boundaries(buffer) do
    case buffer.selection do
      {sx, sy, ex, ey} -> {{sx, sy}, {ex, ey}}
      nil -> nil
    end
  end

  @doc "Delegates to `has_selection?/1`."
  @spec selection_active?(Core.t()) :: boolean()
  def selection_active?(buffer), do: has_selection?(buffer)

  @spec get_selection_start(Core.t()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def get_selection_start(buffer) do
    case buffer.selection do
      {sx, sy, _, _} -> {sx, sy}
      nil -> nil
    end
  end

  @spec get_selection_end(Core.t()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def get_selection_end(buffer) do
    case buffer.selection do
      {sx, sy, sx, sy} -> nil
      {_, _, ex, ey} -> {ex, ey}
      nil -> nil
    end
  end

  # Private helper functions

  defp extract_text_region(buffer, start_x, start_y, end_x, end_y) do
    lines = extract_lines_region(buffer, start_x, start_y, end_x, end_y)
    Enum.join(lines, "\n")
  end

  defp extract_lines_region(buffer, start_x, start_y, end_x, end_y) do
    for y <- start_y..end_y do
      line = Core.get_line(buffer, y)

      {from, to} =
        line_slice_range(y, start_x, start_y, end_x, end_y, buffer.width)

      text =
        line
        |> Enum.slice(from..to)
        |> Enum.map_join("", &cell_to_char/1)

      if start_y == end_y, do: text, else: String.trim_trailing(text)
    end
  end

  defp line_slice_range(y, start_x, y, end_x, y, _width), do: {start_x, end_x}

  defp line_slice_range(y, start_x, y, _end_x, _end_y, width),
    do: {start_x, width - 1}

  defp line_slice_range(y, _start_x, _start_y, end_x, y, _width), do: {0, end_x}

  defp line_slice_range(_y, _start_x, _start_y, _end_x, _end_y, width),
    do: {0, width - 1}

  defp cell_to_char(%Cell{char: char}) when is_binary(char), do: char
  defp cell_to_char(_), do: " "

  defp find_word_boundaries(line, x) do
    # Get character at position
    char_at_x =
      case Enum.at(line, x) do
        %Cell{char: c} when is_binary(c) -> c
        _ -> " "
      end

    # Determine if we're on a word character
    if word_char?(char_at_x) do
      # Find start of word
      start_x = find_word_start(line, x)
      # Find end of word
      end_x = find_word_end(line, x)
      {start_x, end_x}
    else
      # Not on a word, just select the position
      {x, x}
    end
  end

  defp find_word_start(line, x) do
    Enum.reduce_while((x - 1)..0, x, fn i, _acc ->
      check_word_start_char(Enum.at(line, i), i)
    end)
  end

  defp find_word_end(line, x) do
    max_x = length(line) - 1

    Enum.reduce_while((x + 1)..max_x, x, fn i, _acc ->
      check_word_end_char(Enum.at(line, i), i)
    end)
  end

  defp word_char?(char) do
    String.match?(char, ~r/[a-zA-Z0-9_]/)
  end

  defp check_word_start_char(cell, i) do
    case cell do
      %Cell{char: c} when is_binary(c) ->
        if word_char?(c), do: {:cont, i}, else: {:halt, i + 1}

      _ ->
        {:halt, i + 1}
    end
  end

  defp check_word_end_char(cell, i) do
    case cell do
      %Cell{char: c} when is_binary(c) ->
        if word_char?(c), do: {:cont, i}, else: {:halt, i - 1}

      _ ->
        {:halt, i - 1}
    end
  end
end
