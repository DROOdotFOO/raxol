defmodule Raxol.Terminal.ANSI.CachedParser do
  @moduledoc """
  Optimized ANSI parser with caching for common sequences.

  Reduces memory overhead and improves
  performance for frequently used escape sequences.
  """

  @type parsed_token ::
          {:text, binary()}
          | {:csi, binary(), binary()}
          | {:osc, binary()}
          | {:dcs, binary()}
          | {:escape, binary()}

  # Cache for common ANSI sequences
  # These are the most frequently used sequences in terminal applications
  @common_sequences %{
    # SGR (Select Graphic Rendition) - Colors and styles
    # Reset
    "\e[0m" => [{:csi, "0", "m"}],
    # Reset (short form)
    "\e[m" => [{:csi, "", "m"}],
    # Bold
    "\e[1m" => [{:csi, "1", "m"}],
    # Dim
    "\e[2m" => [{:csi, "2", "m"}],
    # Italic
    "\e[3m" => [{:csi, "3", "m"}],
    # Underline
    "\e[4m" => [{:csi, "4", "m"}],
    # Reverse
    "\e[7m" => [{:csi, "7", "m"}],
    # Normal intensity
    "\e[22m" => [{:csi, "22", "m"}],
    # Not italic
    "\e[23m" => [{:csi, "23", "m"}],
    # Not underlined
    "\e[24m" => [{:csi, "24", "m"}],
    # Not reverse
    "\e[27m" => [{:csi, "27", "m"}],

    # Common colors
    # Black foreground
    "\e[30m" => [{:csi, "30", "m"}],
    # Red foreground
    "\e[31m" => [{:csi, "31", "m"}],
    # Green foreground
    "\e[32m" => [{:csi, "32", "m"}],
    # Yellow foreground
    "\e[33m" => [{:csi, "33", "m"}],
    # Blue foreground
    "\e[34m" => [{:csi, "34", "m"}],
    # Magenta foreground
    "\e[35m" => [{:csi, "35", "m"}],
    # Cyan foreground
    "\e[36m" => [{:csi, "36", "m"}],
    # White foreground
    "\e[37m" => [{:csi, "37", "m"}],
    # Default foreground
    "\e[39m" => [{:csi, "39", "m"}],
    # Black background
    "\e[40m" => [{:csi, "40", "m"}],
    # Red background
    "\e[41m" => [{:csi, "41", "m"}],
    # Green background
    "\e[42m" => [{:csi, "42", "m"}],
    # Yellow background
    "\e[43m" => [{:csi, "43", "m"}],
    # Blue background
    "\e[44m" => [{:csi, "44", "m"}],
    # Magenta background
    "\e[45m" => [{:csi, "45", "m"}],
    # Cyan background
    "\e[46m" => [{:csi, "46", "m"}],
    # White background
    "\e[47m" => [{:csi, "47", "m"}],
    # Default background
    "\e[49m" => [{:csi, "49", "m"}],

    # Cursor movement
    # Cursor up
    "\e[A" => [{:csi, "", "A"}],
    # Cursor down
    "\e[B" => [{:csi, "", "B"}],
    # Cursor right
    "\e[C" => [{:csi, "", "C"}],
    # Cursor left
    "\e[D" => [{:csi, "", "D"}],
    # Cursor home
    "\e[H" => [{:csi, "", "H"}],
    # Cursor to 1,1
    "\e[1;1H" => [{:csi, "1;1", "H"}],

    # Erase functions
    # Erase line
    "\e[K" => [{:csi, "", "K"}],
    # Erase to end of line
    "\e[0K" => [{:csi, "0", "K"}],
    # Erase to start of line
    "\e[1K" => [{:csi, "1", "K"}],
    # Erase entire line
    "\e[2K" => [{:csi, "2", "K"}],
    # Erase display
    "\e[J" => [{:csi, "", "J"}],
    # Erase to end of screen
    "\e[0J" => [{:csi, "0", "J"}],
    # Erase to start of screen
    "\e[1J" => [{:csi, "1", "J"}],
    # Erase entire screen
    "\e[2J" => [{:csi, "2", "J"}],

    # Mode changes
    # Show cursor
    "\e[?25h" => [{:csi, "?25", "h"}],
    # Hide cursor
    "\e[?25l" => [{:csi, "?25", "l"}],
    # Use alternate screen
    "\e[?47h" => [{:csi, "?47", "h"}],
    # Use main screen
    "\e[?47l" => [{:csi, "?47", "l"}],
    # Enable alternate screen
    "\e[?1049h" => [{:csi, "?1049", "h"}],
    # Disable alternate screen
    "\e[?1049l" => [{:csi, "?1049", "l"}]
  }

  @doc """
  Parses ANSI escape sequences with caching optimization.

  First checks if the input exactly matches a common cached sequence,
  then falls back to full parsing for complex inputs.
  """
  @spec parse(binary()) :: list(parsed_token())
  def parse(input) when is_binary(input) do
    case Map.get(@common_sequences, input) do
      nil ->
        # Not a simple cached sequence, use full parser
        parse_with_cache_lookup(input)

      cached_result ->
        # Direct cache hit for entire input
        cached_result
    end
  end

  def parse(_), do: []

  # Parse with cache lookup for subsequences
  defp parse_with_cache_lookup(input) do
    case check_for_cached_prefix(input) do
      {cached_result, remaining} ->
        # Found cached prefix, parse remainder
        cached_result ++ parse_with_cache_lookup(remaining)

      nil ->
        # No cached prefix, use original parser
        parse_bytes(input, [], [])
        |> Enum.reverse()
    end
  end

  # Check if input starts with any cached sequence
  defp check_for_cached_prefix(input) do
    @common_sequences
    |> Enum.find_value(fn {cached_seq, result} ->
      if String.starts_with?(input, cached_seq) do
        remaining = String.slice(input, byte_size(cached_seq)..-1//1)
        {result, remaining}
      else
        nil
      end
    end)
  end

  # Original parsing logic for non-cached sequences
  # (Simplified version - delegates to original parser for complex cases)
  defp parse_bytes(input, _text_acc, _acc) do
    # Delegate to the original parser
    # This ensures correctness while we optimize the common cases
    Raxol.Terminal.ANSI.Parser.parse(input)
    |> Enum.reverse()
  end

  @doc """
  Benchmark comparison between cached and original parser.
  """
  def benchmark_comparison(input, iterations \\ 10_000) do
    # Warmup
    Enum.each(1..100, fn _ ->
      _ = parse(input)
      _ = Raxol.Terminal.ANSI.Parser.parse(input)
    end)

    # Benchmark cached parser
    {cached_time, _} =
      :timer.tc(fn ->
        Enum.each(1..iterations, fn _ -> parse(input) end)
      end)

    # Benchmark original parser
    {original_time, _} =
      :timer.tc(fn ->
        Enum.each(1..iterations, fn _ ->
          Raxol.Terminal.ANSI.Parser.parse(input)
        end)
      end)

    cached_avg = cached_time / iterations
    original_avg = original_time / iterations
    improvement = (original_avg - cached_avg) / original_avg * 100

    %{
      input: input,
      cached_time_us: cached_avg,
      original_time_us: original_avg,
      improvement_percent: improvement,
      cached_hit: Map.has_key?(@common_sequences, input)
    }
  end

  @doc """
  Get statistics about cache coverage.
  """
  def cache_stats do
    %{
      cached_sequences: map_size(@common_sequences),
      sequence_types: %{
        # Color and style sequences
        sgr_colors: 21,
        # Cursor positioning
        cursor_movement: 6,
        # Screen/line clearing
        erase_functions: 8,
        # Terminal mode switches
        mode_changes: 6
      },
      total_cache_entries: map_size(@common_sequences)
    }
  end
end
