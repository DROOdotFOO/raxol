defmodule Raxol.UI.ListScorerTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log
  use ExUnitProperties

  alias Raxol.UI.ListScorer

  defp key_fn(item), do: item

  defp items_of(results), do: Enum.map(results, & &1.item)

  describe "rank/4 correctness" do
    test "subsequence match: query chars must appear in order, not necessarily contiguous" do
      items = ["hello", "help", "shell", "world"]
      results = ListScorer.rank(items, "hlo", &key_fn/1)

      assert items_of(results) == ["hello"]
    end

    test "no-match items are excluded entirely" do
      items = ["apple", "banana", "cherry"]
      results = ListScorer.rank(items, "xyz", &key_fn/1)

      assert results == []
    end

    test "empty query returns every item in original order with zero score" do
      items = ["charlie", "alpha", "bravo"]
      results = ListScorer.rank(items, "", &key_fn/1)

      assert items_of(results) == items
      assert Enum.all?(results, &(&1.score == 0.0))
      assert Enum.all?(results, &(&1.positions == []))
    end

    test "case-insensitive by default" do
      results = ListScorer.rank(["HELLO"], "hello", &key_fn/1)
      assert items_of(results) == ["HELLO"]
    end

    test "case_sensitive: true rejects a differently-cased match" do
      assert ListScorer.rank(["HELLO"], "hello", &key_fn/1,
               case_sensitive: true
             ) == []

      assert ListScorer.rank(["HELLO"], "HELLO", &key_fn/1,
               case_sensitive: true
             )
             |> items_of() == ["HELLO"]
    end

    test "positions point at the matched graphemes in the key" do
      [%{positions: positions}] = ListScorer.rank(["hello"], "hlo", &key_fn/1)

      assert Enum.map(positions, &String.at("hello", &1)) == ["h", "l", "o"]
      assert positions == Enum.sort(positions)
    end

    test "adjacency bonus: a contiguous match scores higher than a scattered one" do
      [contig] = ListScorer.rank(["abcdef"], "abc", &key_fn/1)
      [scattered] = ListScorer.rank(["a1b2c3"], "abc", &key_fn/1)

      assert contig.score > scattered.score
    end

    test "word-boundary bonus: a match at a word start scores higher than mid-word" do
      # "foo" matches at position 0 (boundary) in "foo_bar" vs. mid-word in
      # "xfooy" (no boundary before/at the match start).
      [boundary] = ListScorer.rank(["foo_bar"], "foo", &key_fn/1)
      [mid_word] = ListScorer.rank(["xfooy"], "foo", &key_fn/1)

      assert boundary.score > mid_word.score
    end

    test "camelCase transition counts as a word boundary" do
      [camel] = ListScorer.rank(["fooBarBaz"], "bar", &key_fn/1)
      [flat] = ListScorer.rank(["foobarbaz"], "bar", &key_fn/1)

      assert camel.score > flat.score
    end

    test "position bonus: an earlier match scores higher than a later one, all else equal" do
      [earlier] = ListScorer.rank(["ab........."], "ab", &key_fn/1)
      [later] = ListScorer.rank([".........ab"], "ab", &key_fn/1)

      assert earlier.score > later.score
    end

    test "stable sort: ties broken by original list order" do
      # Every item is an exact copy, so every item scores identically --
      # the only thing distinguishing order in the result is input order.
      items = ["same", "same", "same"]
      results = ListScorer.rank(items, "same", &key_fn/1)

      assert items_of(results) == items
    end

    test "higher-scoring items sort first" do
      items = ["a1b2c3", "abc", "xxabcxx"]
      results = ListScorer.rank(items, "abc", &key_fn/1)

      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
      # exact contiguous match at the very start wins
      assert hd(items_of(results)) == "abc"
    end

    test "unicode/CJK: matches operate on graphemes, not bytes or codepoints" do
      results = ListScorer.rank(["日本語のテスト"], "テスト", &key_fn/1)
      assert items_of(results) == ["日本語のテスト"]

      [%{positions: positions, key: key}] = results
      # Grapheme indices must be usable directly against the key string.
      assert Enum.map(positions, &String.at(key, &1)) == ["テ", "ス", "ト"]
    end

    test "unicode: combining-mark graphemes are treated as single units" do
      # "e" + combining acute accent is one grapheme cluster.
      combining_e = "é"
      key = "caf" <> combining_e
      results = ListScorer.rank([key], combining_e, &key_fn/1)

      assert items_of(results) == [key]
      [%{positions: [pos]}] = results
      assert String.at(key, pos) == combining_e
    end

    test "key_fn derives the searchable label independently of the item" do
      items = [%{id: 1, name: "alpha"}, %{id: 2, name: "beta"}]
      results = ListScorer.rank(items, "alp", & &1.name)

      assert items_of(results) == [%{id: 1, name: "alpha"}]
      assert hd(results).key == "alpha"
    end
  end

  describe "properties" do
    property "rank is a permutation-subset of the input (no items invented, none duplicated)" do
      check all(
              raw <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 12),
                  min_length: 0,
                  max_length: 30
                ),
              query <- string(:alphanumeric, max_length: 5),
              max_runs: 100
            ) do
        # Tag each string with its index so identical labels stay
        # distinguishable when checking "no duplication".
        items = Enum.with_index(raw)
        results = ListScorer.rank(items, query, fn {s, _i} -> s end)
        result_items = items_of(results)

        assert MapSet.subset?(MapSet.new(result_items), MapSet.new(items))
        assert length(Enum.uniq(result_items)) == length(result_items)
      end
    end

    property "extending the query with one more character never grows the result set" do
      check all(
              raw <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 12),
                  min_length: 0,
                  max_length: 30
                ),
              query <- string(:alphanumeric, max_length: 4),
              extra <- string(:alphanumeric, length: 1),
              max_runs: 100
            ) do
        items = Enum.with_index(raw)
        key = fn {s, _i} -> s end

        short_set =
          items |> ListScorer.rank(query, key) |> items_of() |> MapSet.new()

        long_set =
          items
          |> ListScorer.rank(query <> extra, key)
          |> items_of()
          |> MapSet.new()

        assert MapSet.subset?(long_set, short_set)
      end
    end
  end

  describe "long keys" do
    test "a ~1,000,000-grapheme adversarial label still matches and keeps its full key" do
      # Nothing else in this suite exercises a long K: the realistic corpus
      # caps out around ~20 chars/label. The `@max_score_graphemes` clamp
      # in `ListScorer` bounds the O(query length * key length) DP (and its
      # two-pointer subsequence pre-check) so an unbounded paste, or a log line
      # used as a list key, can't make a single keystroke's filter pass
      # arbitrarily slow. The clamp only bounds the internal scoring lists;
      # `key:` itself is never truncated, so callers (Picker's `render_row`)
      # keep highlighting the real label, not a truncated stand-in. This is the
      # deterministic half; the timing lives in
      # bench/features/list_scorer_benchmark.exs.
      long_label = "prefix-match-" <> String.duplicate("x", 1_000_000)
      items = ["short-one", long_label, "short-two"]
      query = "prefix-match"

      assert [%{item: matched, key: key}] =
               ListScorer.rank(items, query, &key_fn/1)

      assert matched == long_label
      assert key == long_label
      assert String.length(key) == String.length(long_label)
    end

    test "a match past the scoring cap is missed, so the cap bounds every key" do
      # The guard for the clamp itself. Without `@max_score_graphemes` the
      # 2,000-grapheme label below matches (its "needle" sits past the cap),
      # and scoring cost grows with key length again. The same label with the
      # needle inside the cap still matches.
      past_cap = String.duplicate("x", 2_000) <> "needle"
      within_cap = String.duplicate("x", 1_000) <> "needle"

      past = ListScorer.rank([past_cap, "needle-short"], "needle", &key_fn/1)
      assert items_of(past) == ["needle-short"]

      within = ListScorer.rank([within_cap], "needle", &key_fn/1)
      assert items_of(within) == [within_cap]
    end
  end
end
