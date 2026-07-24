defmodule Raxol.Navigation.Vim do
  @moduledoc """
  VIM-style navigation for terminal buffers.

  Provides familiar VIM keybindings for buffer navigation including:
  - Basic movement (h, j, k, l)
  - Jump commands (gg, G, 0, $)
  - Word movement (w, b, e)
  - Search (/, ?, n, N)
  - Visual mode selection

  ## Example

      state = Vim.new(buffer)
      {:ok, new_state} = Vim.handle_key("j", state)  # Move down
      {:ok, new_state} = Vim.handle_key("w", state)  # Next word
      {:ok, new_state} = Vim.handle_key("/", state)  # Start search

  ## Configuration

      config = %{
        wrap_horizontal: true,
        wrap_vertical: false,
        word_separators: " .,;:!?",
        search_incremental: true
      }

      state = Vim.new(buffer, config)
  """

  alias Raxol.Core.Buffer
  alias Raxol.UI.TextMeasure

  @type position :: {non_neg_integer(), non_neg_integer()}
  @type mode :: :normal | :search | :visual
  @type search_direction :: :forward | :backward

  @type t :: %__MODULE__{
          buffer: Buffer.t(),
          cursor: position(),
          mode: mode(),
          config: map(),
          search_pattern: String.t() | nil,
          search_direction: search_direction() | nil,
          search_matches: [position()],
          search_index: non_neg_integer(),
          visual_start: position() | nil,
          command_buffer: String.t()
        }

  defstruct buffer: nil,
            cursor: {0, 0},
            mode: :normal,
            config: %{},
            search_pattern: nil,
            search_direction: nil,
            search_matches: [],
            search_index: 0,
            visual_start: nil,
            command_buffer: ""

  @doc """
  Create a new VIM navigation state.
  """
  @spec new(Buffer.t(), map()) :: t()
  def new(buffer, config \\ %{}) do
    default_config = %{
      wrap_horizontal: true,
      wrap_vertical: false,
      word_separators: " .,;:!?",
      search_incremental: true
    }

    %__MODULE__{
      buffer: buffer,
      cursor: {0, 0},
      config: Map.merge(default_config, config)
    }
  end

  @doc """
  Handle a key press and update navigation state.
  """
  @spec handle_key(String.t(), t()) :: {:ok, t()} | {:error, String.t()}
  def handle_key(key, %__MODULE__{mode: :search} = state) do
    handle_search_key(key, state)
  end

  def handle_key(key, %__MODULE__{mode: :visual} = state) do
    handle_visual_key(key, state)
  end

  def handle_key(key, %__MODULE__{mode: :normal} = state) do
    handle_normal_key(key, state)
  end

  # Normal mode navigation

  defp handle_normal_key("h", state), do: move_left(state)
  defp handle_normal_key("j", state), do: move_down(state)
  defp handle_normal_key("k", state), do: move_up(state)
  defp handle_normal_key("l", state), do: move_right(state)

  defp handle_normal_key("w", state), do: word_forward(state)
  defp handle_normal_key("b", state), do: word_backward(state)
  defp handle_normal_key("e", state), do: word_end(state)

  defp handle_normal_key("0", state), do: line_start(state)
  defp handle_normal_key("$", state), do: line_end(state)

  defp handle_normal_key("gg", state), do: buffer_top(state)
  defp handle_normal_key("G", state), do: buffer_bottom(state)

  defp handle_normal_key("/", state), do: start_search(state, :forward)
  defp handle_normal_key("?", state), do: start_search(state, :backward)
  defp handle_normal_key("n", state), do: next_match(state)
  defp handle_normal_key("N", state), do: previous_match(state)

  defp handle_normal_key("v", state), do: enter_visual_mode(state)

  defp handle_normal_key(_key, state), do: {:ok, state}

  # Movement functions

  defp move_left(%{cursor: {x, y}, buffer: buffer, config: config} = state) do
    new_x = if x > 0, do: x - 1, else: maybe_wrap_left(y, buffer, config)

    new_state =
      if is_integer(new_x) do
        %{state | cursor: {new_x, y}}
      else
        case new_x do
          {:wrap, new_x, new_y} -> %{state | cursor: {new_x, new_y}}
          :no_wrap -> state
        end
      end

    {:ok, new_state}
  end

  defp move_down(%{cursor: {x, y}, buffer: buffer} = state) do
    max_y = buffer.height - 1

    new_y = if y < max_y, do: y + 1, else: y
    new_state = %{state | cursor: {x, new_y}}

    {:ok, new_state}
  end

  defp move_up(%{cursor: {x, y}} = state) do
    new_y = if y > 0, do: y - 1, else: 0
    new_state = %{state | cursor: {x, new_y}}

    {:ok, new_state}
  end

  defp move_right(%{cursor: {x, y}, buffer: buffer, config: config} = state) do
    max_x = buffer.width - 1

    new_x = if x < max_x, do: x + 1, else: maybe_wrap_right(y, buffer, config)

    new_state =
      if is_integer(new_x) do
        %{state | cursor: {new_x, y}}
      else
        case new_x do
          {:wrap, new_x, new_y} -> %{state | cursor: {new_x, new_y}}
          :no_wrap -> state
        end
      end

    {:ok, new_state}
  end

  defp maybe_wrap_left(y, buffer, %{wrap_horizontal: true}) when y > 0 do
    {:wrap, buffer.width - 1, y - 1}
  end

  defp maybe_wrap_left(_y, _buffer, _config), do: :no_wrap

  defp maybe_wrap_right(y, buffer, %{wrap_horizontal: true}) do
    if y < buffer.height - 1 do
      {:wrap, 0, y + 1}
    else
      :no_wrap
    end
  end

  defp maybe_wrap_right(_y, _buffer, _config), do: :no_wrap

  # Word movement

  defp word_forward(%{cursor: {x, y}, buffer: buffer, config: config} = state) do
    line = get_line_text(buffer, y)
    separators = config.word_separators

    new_x = find_next_word_start(line, x, separators)

    new_state =
      if new_x do
        %{state | cursor: {new_x, y}}
      else
        # Move to next line
        if y < buffer.height - 1 do
          %{state | cursor: {0, y + 1}}
        else
          state
        end
      end

    {:ok, new_state}
  end

  defp word_backward(%{cursor: {x, y}, buffer: buffer, config: config} = state) do
    line = get_line_text(buffer, y)
    separators = config.word_separators

    new_x = find_prev_word_start(line, x, separators)

    new_state =
      if new_x do
        %{state | cursor: {new_x, y}}
      else
        # Move to previous line
        if y > 0 do
          prev_line = get_line_text(buffer, y - 1)
          %{state | cursor: {String.length(prev_line), y - 1}}
        else
          state
        end
      end

    {:ok, new_state}
  end

  defp word_end(%{cursor: {x, y}, buffer: buffer, config: config} = state) do
    line = get_line_text(buffer, y)
    separators = config.word_separators

    new_x = find_word_end(line, x, separators)
    new_state = %{state | cursor: {new_x, y}}

    {:ok, new_state}
  end

  # Jump commands

  defp line_start(state) do
    {_x, y} = state.cursor
    {:ok, %{state | cursor: {0, y}}}
  end

  defp line_end(%{cursor: {_x, y}, buffer: buffer} = state) do
    line = get_line_text(buffer, y)
    max_x = max(0, String.length(line) - 1)
    {:ok, %{state | cursor: {max_x, y}}}
  end

  defp buffer_top(state) do
    {:ok, %{state | cursor: {0, 0}}}
  end

  defp buffer_bottom(%{buffer: buffer} = state) do
    max_y = buffer.height - 1
    {:ok, %{state | cursor: {0, max_y}}}
  end

  # Search mode

  defp start_search(state, direction) do
    {:ok,
     %{
       state
       | mode: :search,
         search_direction: direction,
         command_buffer: ""
     }}
  end

  defp handle_search_key("Enter", state) do
    execute_search(state)
  end

  defp handle_search_key("Escape", state) do
    {:ok, %{state | mode: :normal, command_buffer: ""}}
  end

  defp handle_search_key("Backspace", %{command_buffer: buffer} = state) do
    new_buffer = String.slice(buffer, 0..-2//1)
    {:ok, %{state | command_buffer: new_buffer}}
  end

  defp handle_search_key(char, %{command_buffer: buffer} = state)
       when byte_size(char) == 1 do
    new_buffer = buffer <> char
    {:ok, %{state | command_buffer: new_buffer}}
  end

  defp handle_search_key(_key, state), do: {:ok, state}

  defp execute_search(%{command_buffer: pattern, buffer: buffer} = state) do
    matches = find_all_matches(buffer, pattern)

    new_state = %{
      state
      | mode: :normal,
        search_pattern: pattern,
        search_matches: matches,
        search_index: 0,
        command_buffer: ""
    }

    if matches != [] do
      {:ok, %{new_state | cursor: hd(matches)}}
    else
      {:ok, new_state}
    end
  end

  defp next_match(%{search_matches: []} = state), do: {:ok, state}

  defp next_match(%{search_matches: matches, search_index: idx} = state) do
    new_idx = rem(idx + 1, length(matches))
    new_cursor = Enum.at(matches, new_idx)

    {:ok, %{state | search_index: new_idx, cursor: new_cursor}}
  end

  defp previous_match(%{search_matches: []} = state), do: {:ok, state}

  defp previous_match(%{search_matches: matches, search_index: idx} = state) do
    new_idx = rem(idx - 1 + length(matches), length(matches))
    new_cursor = Enum.at(matches, new_idx)

    {:ok, %{state | search_index: new_idx, cursor: new_cursor}}
  end

  # Visual mode

  defp enter_visual_mode(%{cursor: cursor} = state) do
    {:ok, %{state | mode: :visual, visual_start: cursor}}
  end

  defp handle_visual_key("Escape", state) do
    {:ok, %{state | mode: :normal, visual_start: nil}}
  end

  defp handle_visual_key(key, state) do
    # Handle movement in visual mode (same as normal)
    {:ok, new_state} = handle_normal_key(key, state)
    {:ok, %{new_state | mode: :visual}}
  end

  @doc """
  Get the current visual selection range.
  """
  @spec get_selection(t()) :: {position(), position()} | nil
  def get_selection(%{mode: :visual, visual_start: start, cursor: cursor}) do
    {min_pos, max_pos} = order_positions(start, cursor)
    {min_pos, max_pos}
  end

  def get_selection(_state), do: nil

  # Helper functions

  defp get_line_text(buffer, y) do
    line = Enum.at(buffer.lines, y)

    if line do
      Enum.map_join(line.cells, "", & &1.char)
    else
      ""
    end
  end

  defp find_next_word_start(line, x, separators) do
    # Skip to next position
    start_pos = x + 1

    # Skip separators character by character
    separator_chars = String.graphemes(separators)

    offset =
      line
      |> String.slice(start_pos..-1//1)
      |> String.graphemes()
      |> Enum.take_while(fn char -> char in separator_chars end)
      |> length()

    pos = start_pos + offset

    # Check if we found a non-separator character
    if pos < String.length(line) and String.at(line, pos) not in separator_chars do
      pos
    else
      nil
    end
  end

  defp find_prev_word_start(line, x, separators) do
    if x <= 0 do
      nil
    else
      # Get text before cursor
      before = String.slice(line, 0..(x - 1))

      # Trim separators from end
      trimmed = String.trim_trailing(before, separators)

      if trimmed == "" do
        0
      else
        # Find start of word
        words = String.split(trimmed, separators, trim: true)
        last_word = List.last(words) || ""
        String.length(trimmed) - String.length(last_word)
      end
    end
  end

  defp find_word_end(line, x, separators) do
    rest = String.slice(line, x..-1//1)

    # Find next separator
    case Regex.run(~r/[#{Regex.escape(separators)}]/, rest) do
      nil ->
        String.length(line) - 1

      [sep] ->
        x + String.length(rest) -
          String.length(String.split(rest, sep, parts: 2) |> List.last())
    end
  end

  defp find_all_matches(buffer, pattern) do
    for {line, y} <- Enum.with_index(buffer.lines),
        line_text = get_line_cells_text(line),
        match_x <- find_in_line(line_text, pattern) do
      {match_x, y}
    end
  end

  defp get_line_cells_text(%{cells: cells}) do
    Enum.map_join(cells, "", & &1.char)
  end

  # `return: :index` gives BYTE offsets, but the caller uses these as `x`
  # cursor positions into `Core.Buffer`, which stores one cell per GRAPHEME
  # (so `x` is a grapheme index -- the same unit `line_end/1` and
  # `word_backward/1` derive from `String.length/1`). Returning the raw
  # byte offset put the cursor past the match on any line containing a
  # multi-byte character, and further past it with each additional one.
  defp find_in_line(text, pattern) do
    case Regex.scan(~r/#{Regex.escape(pattern)}/, text, return: :index) do
      [] ->
        []

      matches ->
        Enum.map(matches, fn [{start, _length}] ->
          TextMeasure.byte_offset_to_index(text, start)
        end)
    end
  end

  defp order_positions({x1, y1}, {x2, y2}) when y1 < y2,
    do: {{x1, y1}, {x2, y2}}

  defp order_positions({x1, y1}, {x2, y2}) when y1 > y2,
    do: {{x2, y2}, {x1, y1}}

  defp order_positions({x1, y1}, {x2, y2}) when x1 <= x2,
    do: {{x1, y1}, {x2, y2}}

  defp order_positions({x1, y1}, {x2, y2}), do: {{x2, y2}, {x1, y1}}
end
