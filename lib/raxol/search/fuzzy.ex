defmodule Raxol.Search.Fuzzy do
  @moduledoc """
  Search system with fuzzy, exact, and regex matching.

  Provides multiple search modes for finding text in terminal buffers:
  - Fuzzy matching (like fzf)
  - Exact string matching
  - Regular expression matching
  - Result highlighting
  - Navigation with n/N

  ## Example

      buffer = Buffer.create_blank_buffer(80, 24)
      # ... populate buffer ...

      # Fuzzy search
      results = Fuzzy.search(buffer, "hlo", :fuzzy)
      # Matches "hello", "halo", etc.

      # Exact search
      results = Fuzzy.search(buffer, "hello", :exact)

      # Regex search
      results = Fuzzy.search(buffer, ~r/h.llo/, :regex)

  Note: list-item ranking (picker/palette/session filtering) lives in
  `Raxol.UI.ListScorer`, a separate module -- this one searches buffer
  cells, a different problem category.
  """

  require Logger

  alias Raxol.Core.Buffer

  @type position :: {non_neg_integer(), non_neg_integer()}
  @type match :: %{
          position: position(),
          text: String.t(),
          score: float(),
          highlight: list({non_neg_integer(), non_neg_integer()})
        }

  @type search_mode :: :fuzzy | :exact | :regex

  @type t :: %__MODULE__{
          buffer: Buffer.t(),
          query: String.t(),
          mode: search_mode(),
          matches: list(match()),
          current_index: non_neg_integer(),
          case_sensitive: boolean()
        }

  defstruct buffer: nil,
            query: "",
            mode: :fuzzy,
            matches: [],
            current_index: 0,
            case_sensitive: false

  @doc """
  Create a new search state.
  """
  @spec new(Buffer.t(), map()) :: t()
  def new(buffer, opts \\ %{}) do
    %__MODULE__{
      buffer: buffer,
      mode: opts[:mode] || :fuzzy,
      case_sensitive: opts[:case_sensitive] || false
    }
  end

  @doc """
  Perform a search on the buffer.
  """
  @spec search(Buffer.t(), String.t(), search_mode(), map()) :: list(match())
  def search(buffer, query, mode \\ :fuzzy, opts \\ %{}) do
    case_sensitive = opts[:case_sensitive] || false

    buffer.lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, y} ->
      search_line(line, y, query, mode, case_sensitive)
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc """
  Update search query and find new matches.
  """
  @spec update_query(t(), String.t()) :: t()
  def update_query(
        %__MODULE__{buffer: buffer, mode: mode, case_sensitive: case_sensitive} =
          state,
        query
      ) do
    matches = search(buffer, query, mode, %{case_sensitive: case_sensitive})

    %{state | query: query, matches: matches, current_index: 0}
  end

  @doc """
  Navigate to next match.
  """
  @spec next_match(t()) :: t()
  def next_match(%{matches: []} = state), do: state

  def next_match(%{matches: matches, current_index: idx} = state) do
    new_idx = rem(idx + 1, length(matches))
    %{state | current_index: new_idx}
  end

  @doc """
  Navigate to previous match.
  """
  @spec previous_match(t()) :: t()
  def previous_match(%{matches: []} = state), do: state

  def previous_match(%{matches: matches, current_index: idx} = state) do
    new_idx = rem(idx - 1 + length(matches), length(matches))
    %{state | current_index: new_idx}
  end

  @doc """
  Get current match position.
  """
  @spec get_current_match(t()) :: match() | nil
  def get_current_match(%{matches: []}) do
    nil
  end

  def get_current_match(%{matches: matches, current_index: idx}) do
    Enum.at(matches, idx)
  end

  def get_current_match(_state), do: nil

  @doc """
  Get all match positions.
  """
  @spec get_all_matches(t()) :: list(position())
  def get_all_matches(%{matches: matches}) do
    Enum.map(matches, & &1.position)
  end

  # Private functions

  defp search_line(line, y, query, mode, case_sensitive) do
    line_text = get_line_text(line)
    do_search_line(line_text, y, query, mode, case_sensitive)
  end

  defp do_search_line(_text, _y, "", mode, _cs) when mode in [:fuzzy, :exact],
    do: []

  defp do_search_line(line_text, y, query, :fuzzy, case_sensitive) do
    {norm_text, norm_query} = normalize_pair(line_text, query, case_sensitive)
    fuzzy_search_line(norm_text, norm_query, y, line_text)
  end

  defp do_search_line(line_text, y, query, :exact, case_sensitive) do
    {norm_text, norm_query} = normalize_pair(line_text, query, case_sensitive)
    exact_search_line(norm_text, norm_query, y, line_text)
  end

  defp do_search_line(line_text, y, query, :regex, _case_sensitive) do
    regex_search_line(line_text, query, y, line_text)
  end

  defp normalize_pair(text, query, true), do: {text, query}

  defp normalize_pair(text, query, false),
    do: {String.downcase(text), String.downcase(query)}

  defp get_line_text(%{cells: cells}) do
    Enum.map_join(cells, "", & &1.char)
  end

  # Fuzzy matching

  defp fuzzy_search_line(text, query, y, original_text) do
    case fuzzy_match(text, query) do
      {:ok, score, positions} when positions != [] ->
        [
          %{
            position: {hd(positions), y},
            text: original_text,
            score: score,
            highlight: positions
          }
        ]

      _ ->
        []
    end
  end

  defp fuzzy_match(text, query) do
    query_chars = String.graphemes(query)

    case find_fuzzy_positions(text, query_chars, 0, []) do
      {:ok, positions} ->
        score = calculate_fuzzy_score(positions, String.length(text))
        {:ok, score, positions}

      :no_match ->
        :no_match
    end
  end

  defp find_fuzzy_positions(_text, [], _offset, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp find_fuzzy_positions(text, [char | rest_query], offset, acc) do
    case find_char_position(text, char, offset) do
      nil ->
        :no_match

      pos ->
        find_fuzzy_positions(text, rest_query, pos + 1, [pos | acc])
    end
  end

  defp find_char_position(text, char, start_pos) do
    rest = String.slice(text, start_pos..-1//1)

    case String.split(rest, char, parts: 2) do
      [before, _after] -> start_pos + String.length(before)
      [_] -> nil
    end
  end

  defp calculate_fuzzy_score(positions, text_length) do
    # Score based on:
    # - How early the match starts (earlier is better)
    # - How close together the matched characters are (closer is better)
    # - Percentage of text matched

    if positions == [] do
      0.0
    else
      first_pos = hd(positions)
      last_pos = List.last(positions)
      span = last_pos - first_pos + 1
      match_length = length(positions)

      # Earlier matches score higher
      position_score = 1.0 - first_pos / text_length

      # Tighter matches score higher
      tightness_score = match_length / span

      # Combine scores
      (position_score + tightness_score) / 2
    end
  end

  # Exact matching

  defp exact_search_line(text, query, y, original_text) do
    find_all_occurrences(text, query)
    |> Enum.map(fn x ->
      %{
        position: {x, y},
        text: original_text,
        score: 1.0,
        highlight: Enum.to_list(x..(x + String.length(query) - 1))
      }
    end)
  end

  defp find_all_occurrences(text, query) do
    do_find_occurrences(text, query, 0, [])
    |> Enum.reverse()
  end

  defp do_find_occurrences(text, query, offset, acc) do
    rest = String.slice(text, offset..-1//1)

    case String.split(rest, query, parts: 2) do
      [before, _after_part] ->
        pos = offset + String.length(before)
        new_offset = pos + String.length(query)
        do_find_occurrences(text, query, new_offset, [pos | acc])

      [_] ->
        acc
    end
  end

  # Regex matching

  defp regex_search_line(text, pattern, y, original_text) do
    regex =
      cond do
        is_struct(pattern, Regex) -> pattern
        is_binary(pattern) -> Regex.compile!(pattern)
        true -> ~r//
      end

    case Regex.scan(regex, text, return: :index) do
      [] ->
        []

      matches ->
        Enum.map(matches, fn [{start, length}] ->
          %{
            position: {start, y},
            text: original_text,
            score: 1.0,
            highlight: Enum.to_list(start..(start + length - 1))
          }
        end)
    end
  rescue
    e ->
      Logger.warning("Regex search failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Highlight search results in buffer.

  Returns a new buffer with highlighted matches.
  """
  @spec highlight_matches(Buffer.t(), list(match()), map()) :: Buffer.t()
  def highlight_matches(buffer, matches, style \\ %{}) do
    default_style = %{bg_color: :yellow, fg_color: :black}
    highlight_style = Map.merge(default_style, style)

    Enum.reduce(matches, buffer, fn match, buf ->
      highlight_match(buf, match, highlight_style)
    end)
  end

  defp highlight_match(
         buffer,
         %{position: {_x, y}, highlight: positions},
         style
       ) do
    Enum.reduce(positions, buffer, fn pos, buf ->
      cell = Buffer.get_cell(buf, pos, y)
      new_style = Map.merge(cell.style, style)
      Buffer.set_cell(buf, pos, y, cell.char, new_style)
    end)
  end

  @doc """
  Get search statistics.
  """
  @spec get_stats(t()) :: map()
  def get_stats(%{matches: matches, current_index: idx, query: query}) do
    %{
      total_matches: length(matches),
      current: idx + 1,
      query: query
    }
  end
end
