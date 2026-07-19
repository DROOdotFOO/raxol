defmodule Raxol.UI.ListScorerTest do
  use ExUnit.Case, async: true
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

  describe "performance" do
    # Realistic-shaped labels (branch-name-like: `word-word-word-hex`,
    # drawn from a 23-word vocabulary so a query narrows the match set
    # instead of matching everything) rather than a synthetic corpus
    # where every item literally contains the query -- see the module
    # note below for why that distinction is the whole ballgame here.
    defp realistic_items(vocab, count) do
      for i <- 1..count do
        words = for _ <- 1..3, do: Enum.random(vocab)
        Enum.join(words, "-") <> "-" <> Integer.to_string(:erlang.phash2(i), 16)
      end
    end

    @vocab ~w(harness agent payments gateway terminal render picker session
              swarm acp symphony core plugin liveview speech watch telegram
              fix feat chore test docs refactor)

    @tag :bench
    @tag :slow
    test "ranks 10k items well under 16ms/keystroke for a narrowing query" do
      items = realistic_items(@vocab, 10_000)
      # A 3+ character fragment -- what a picker sees after a couple of
      # keystrokes -- narrows the match set the way real typing does.
      query = "harn"

      # Warm the code path once before timing (BEAM JIT/first-call cost
      # would otherwise pollute a single-shot measurement).
      ListScorer.rank(items, query, &key_fn/1)

      {micros, results} =
        :timer.tc(fn -> ListScorer.rank(items, query, &key_fn/1) end)

      millis = micros / 1000

      IO.puts(
        "[bench] ListScorer.rank/4, 10,000 realistic items, query #{inspect(query)}: " <>
          "#{Float.round(millis, 3)}ms (#{length(results)}/10000 matched)"
      )

      assert millis < 16.0,
             "expected 10k-item filter under 16ms/keystroke, took #{millis}ms"
    end

    @tag :bench
    @tag :slow
    test "characterizes the pathological worst case: every item matches" do
      # Honesty check on the target, not a claim it's met here: if every
      # single item in a 10k-item list shares the literal query as a
      # substring (a degenerate corpus no real picker would show -- fuzzy
      # filtering exists precisely because most items DON'T match), the
      # full Smith-Waterman-lite DP + backtrack runs for all 10,000 of
      # them. That's a materially different cost profile from the
      # narrowing case above (which rejects most items in the O(query +
      # key) two-pointer subsequence check before ever reaching the DP).
      # This test measures and reports that ceiling; it intentionally
      # does not assert 16ms against it -- see the commit body for the
      # measured number and the honest read on what it means.
      items =
        for i <- 1..10_000 do
          "session-#{Integer.to_string(i, 16)}-#{:erlang.phash2(i)}-item"
        end

      query = "session"

      ListScorer.rank(items, query, &key_fn/1)

      {micros, results} =
        :timer.tc(fn -> ListScorer.rank(items, query, &key_fn/1) end)

      millis = micros / 1000

      IO.puts(
        "[bench] ListScorer.rank/4, 10,000/10,000-match pathological case: " <>
          "#{Float.round(millis, 3)}ms (#{length(results)} matches)"
      )

      # Regression guard only (order-of-magnitude), not the 16ms target.
      assert millis < 200.0,
             "pathological all-match case regressed badly: #{millis}ms"
    end

    test "a ~1,000,000-grapheme adversarial label still matches and keeps its full key" do
      # Nothing else in this suite exercises a long K: the realistic corpus
      # above caps out around ~20 chars/label. The `@max_score_graphemes` clamp
      # in `ListScorer` bounds the O(query length * key length) DP (and its
      # two-pointer subsequence pre-check) so an unbounded paste, or a log line
      # used as a list key, can't make a single keystroke's filter pass
      # arbitrarily slow. The clamp only bounds the internal scoring lists;
      # `key:` itself is never truncated, so callers (Picker's `render_row`)
      # keep highlighting the real label, not a truncated stand-in. This is the
      # deterministic half; the wall-clock guard lives in the :slow test below.
      long_label = "prefix-match-" <> String.duplicate("x", 1_000_000)
      items = ["short-one", long_label, "short-two"]
      query = "prefix-match"

      assert [%{item: matched, key: key}] = ListScorer.rank(items, query, &key_fn/1)
      assert matched == long_label
      assert key == long_label
      assert String.length(key) == String.length(long_label)
    end

    @tag :bench
    @tag :slow
    test "a single ~1,000,000-grapheme adversarial label stays bounded" do
      # Perf regression guard for the clamp: without `@max_score_graphemes`, the
      # O(query * key) DP over a 1M-grapheme label costs seconds. This is a
      # wall-clock assertion on a shared runner, so it carries :slow/:bench
      # (excluded from PR CI) like the sibling benchmarks above -- a 200ms target
      # still flaked on loaded macOS CI at ~25ms with the clamp working. Runs
      # locally and on the nightly slow suite.
      long_label = "prefix-match-" <> String.duplicate("x", 1_000_000)
      items = ["short-one", long_label, "short-two"]
      query = "prefix-match"

      {micros, _results} =
        :timer.tc(fn -> ListScorer.rank(items, query, &key_fn/1) end)

      millis = micros / 1000

      assert millis < 200.0,
             "expected the 1M-grapheme adversarial label to stay bounded, took #{millis}ms"
    end
  end
end
