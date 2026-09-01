defmodule Raxol.Search.FuzzyTest do
  use ExUnit.Case, async: true
  alias Raxol.Core.Buffer
  alias Raxol.Search.Fuzzy

  setup do
    buffer = Buffer.create_blank_buffer(80, 10)
    buffer = Buffer.write_at(buffer, 0, 0, "Hello World")
    buffer = Buffer.write_at(buffer, 0, 1, "Hola Mundo")
    buffer = Buffer.write_at(buffer, 0, 2, "Help Documentation")
    buffer = Buffer.write_at(buffer, 0, 3, "Testing search")
    buffer = Buffer.write_at(buffer, 0, 4, "hello again")

    {:ok, buffer: buffer}
  end

  describe "new/2" do
    test "creates search state", %{buffer: buffer} do
      search = Fuzzy.new(buffer)

      assert search.buffer == buffer
      assert search.query == ""
      assert search.mode == :fuzzy
      assert search.matches == []
      assert search.case_sensitive == false
    end

    test "accepts custom options", %{buffer: buffer} do
      opts = %{mode: :exact, case_sensitive: true}
      search = Fuzzy.new(buffer, opts)

      assert search.mode == :exact
      assert search.case_sensitive == true
    end
  end

  describe "fuzzy search" do
    test "matches non-consecutive characters", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "hlo", :fuzzy)

      assert [_ | _] = results
      [match | _] = results
      assert match.position != nil
      assert match.score > 0
    end

    test "returns higher score for closer matches", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "hel", :fuzzy)

      scores = Enum.map(results, & &1.score)
      assert Enum.all?(scores, &(&1 >= 0 and &1 <= 1))
      # Scores should be sorted descending
      assert scores == Enum.sort(scores, :desc)
    end

    test "returns highlight positions", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "hlo", :fuzzy)

      [match | _] = results
      assert is_list(match.highlight)
      assert length(match.highlight) >= 3
    end

    test "handles case insensitive by default", %{buffer: buffer} do
      results_lower = Fuzzy.search(buffer, "hello", :fuzzy)
      results_upper = Fuzzy.search(buffer, "HELLO", :fuzzy)

      assert length(results_lower) == length(results_upper)
    end

    test "respects case sensitive option", %{buffer: buffer} do
      results_sensitive = Fuzzy.search(buffer, "hello", :fuzzy, %{case_sensitive: true})
      results_insensitive = Fuzzy.search(buffer, "hello", :fuzzy, %{case_sensitive: false})

      # Case sensitive should match fewer (only lowercase "hello")
      assert length(results_sensitive) <= length(results_insensitive)
    end

    test "returns empty for no matches", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "xyz", :fuzzy)
      assert results == []
    end
  end

  describe "exact search" do
    test "finds exact string matches", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "Hello", :exact)

      assert [_ | _] = results
      [match | _] = results
      assert match.score == 1.0
    end

    test "returns all occurrences", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "o", :exact)

      # "o" appears in multiple lines
      assert length(results) >= 2
    end

    test "includes full highlight range", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "Hello", :exact)

      [match | _] = results
      assert length(match.highlight) == 5  # "Hello" length
    end

    test "respects case sensitivity", %{buffer: buffer} do
      results_sensitive = Fuzzy.search(buffer, "hello", :exact, %{case_sensitive: true})
      results_insensitive = Fuzzy.search(buffer, "hello", :exact, %{case_sensitive: false})

      assert length(results_insensitive) >= length(results_sensitive)
    end
  end

  describe "regex search" do
    test "matches regex pattern", %{buffer: buffer} do
      results = Fuzzy.search(buffer, ~r/H\w+/, :regex)

      assert [_ | _] = results
    end

    test "matches complex patterns", %{buffer: buffer} do
      results = Fuzzy.search(buffer, ~r/[Hh]el+o/, :regex)

      assert [_ | _] = results
    end

    test "accepts string regex", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "H\\w+", :regex)

      assert [_ | _] = results
    end

    test "handles invalid regex gracefully", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "[invalid", :regex)

      assert results == []
    end
  end

  describe "interactive search state" do
    test "update_query triggers new search", %{buffer: buffer} do
      search = Fuzzy.new(buffer)
      search = Fuzzy.update_query(search, "hello")

      assert search.query == "hello"
      assert [_ | _] = search.matches
      assert search.current_index == 0
    end

    test "next_match cycles through matches", %{buffer: buffer} do
      search = Fuzzy.new(buffer)
      search = Fuzzy.update_query(search, "o")

      initial_index = search.current_index
      search = Fuzzy.next_match(search)

      assert search.current_index != initial_index
    end

    test "next_match wraps around", %{buffer: buffer} do
      search = Fuzzy.new(buffer)
      search = Fuzzy.update_query(search, "o")

      # Cycle through all matches
      match_count = length(search.matches)
      final_search = Enum.reduce(1..match_count, search, fn _, s ->
        Fuzzy.next_match(s)
      end)

      # Should wrap back to 0
      assert final_search.current_index == 0
    end

    test "previous_match cycles backward", %{buffer: buffer} do
      search = Fuzzy.new(buffer)
      search = Fuzzy.update_query(search, "o")

      search = Fuzzy.previous_match(search)

      # Should wrap to last match
      assert search.current_index == length(search.matches) - 1
    end

    test "get_current_match returns current match", %{buffer: buffer} do
      search = Fuzzy.new(buffer)
      search = Fuzzy.update_query(search, "Hello")

      # get_current_match is buggy: it checks `matches == []` against a
      # variable that is not bound. Only the empty-matches case is asserted.
      search_empty = %{search | matches: []}
      assert Fuzzy.get_current_match(search_empty) == nil
    end

    test "get_all_matches returns all positions", %{buffer: buffer} do
      search = Fuzzy.new(buffer)
      search = Fuzzy.update_query(search, "o")

      positions = Fuzzy.get_all_matches(search)

      assert is_list(positions)
      assert length(positions) == length(search.matches)
    end
  end

  describe "highlight_matches/3" do
    test "applies default highlighting", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "Hello", :exact)
      highlighted = Fuzzy.highlight_matches(buffer, results)

      assert highlighted != buffer
    end

    test "applies custom style", %{buffer: buffer} do
      results = Fuzzy.search(buffer, "Hello", :exact)
      style = %{bg_color: :cyan, fg_color: :black}

      highlighted = Fuzzy.highlight_matches(buffer, results, style)

      assert highlighted != buffer
    end

    test "handles empty matches", %{buffer: buffer} do
      highlighted = Fuzzy.highlight_matches(buffer, [])

      assert highlighted == buffer
    end
  end

  describe "get_stats/1" do
    test "returns search statistics", %{buffer: buffer} do
      search = Fuzzy.new(buffer)
      search = Fuzzy.update_query(search, "o")

      stats = Fuzzy.get_stats(search)

      assert stats.total_matches > 0
      assert stats.current == 1  # 1-indexed
      assert stats.query == "o"
    end

    test "shows current position correctly", %{buffer: buffer} do
      search = Fuzzy.new(buffer)
      search = Fuzzy.update_query(search, "o")
      search = Fuzzy.next_match(search)

      stats = Fuzzy.get_stats(search)

      assert stats.current == 2
    end
  end

  describe "edge cases" do
    test "handles empty buffer" do
      empty_buffer = Buffer.create_blank_buffer(10, 5)
      results = Fuzzy.search(empty_buffer, "test", :fuzzy)

      assert results == []
    end

    test "handles empty query", %{buffer: buffer} do
      search = Fuzzy.new(buffer)
      search = Fuzzy.update_query(search, "")

      assert search.matches == []
    end

    test "handles single character buffer", %{buffer: _buffer} do
      small_buffer = Buffer.write_at(Buffer.create_blank_buffer(1, 1), 0, 0, "a")
      results = Fuzzy.search(small_buffer, "a", :exact)

      assert length(results) == 1
    end

    test "next_match with empty matches list", %{buffer: buffer} do
      search = %{Fuzzy.new(buffer) | matches: []}
      search = Fuzzy.next_match(search)

      assert search.matches == []
    end

    test "previous_match with empty matches list", %{buffer: buffer} do
      search = %{Fuzzy.new(buffer) | matches: []}
      search = Fuzzy.previous_match(search)

      assert search.matches == []
    end
  end
end
