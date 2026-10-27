# ListScorer.rank/3 latency per keystroke.
#
#   MIX_ENV=test mix run --no-start bench/features/list_scorer_benchmark.exs
#
# A report, not a gate: it prints the median of five passes for each case and
# exits 0. These three cases were wall-clock assertions in
# test/raxol/ui/list_scorer_test.exs (`:bench`/`:slow`), where the nightly
# integration job swallowed their failures: the 16 ms row measured 32.9 ms on
# a shared runner and nothing noticed. The deterministic halves of those
# tests (the 1M-grapheme label still matches and keeps its full key) stay in
# the suite.
#
# The 16 ms figure is one frame at 60 fps, the budget a picker has to filter
# on each keystroke. Only the narrowing case is held to it; the all-match case
# is a degenerate corpus and is printed for the ceiling it shows.

alias Raxol.UI.ListScorer

defmodule ListScorerBench do
  @passes 5

  def median_ms(fun) do
    fun.()

    for _ <- 1..@passes do
      {micros, _} = :timer.tc(fun)
      micros / 1000
    end
    |> Enum.sort()
    |> Enum.at(div(@passes, 2))
  end

  def report(label, ms, extra) do
    IO.puts(
      String.pad_trailing(label, 52) <>
        :erlang.float_to_binary(ms, decimals: 3) <> " ms  " <> extra
    )
  end
end

key_fn = & &1

# Branch-name-shaped labels from a 23-word vocabulary, so a 4-character query
# narrows the match set the way real typing does. Seeded for a stable corpus.
:rand.seed(:exsss, {1, 2, 3})

vocab =
  ~w(harness agent payments gateway terminal render picker session swarm acp
     journal core plugin liveview speech watch telegram fix feat chore test
     docs refactor)

realistic =
  for i <- 1..10_000 do
    words = for _ <- 1..3, do: Enum.random(vocab)
    Enum.join(words, "-") <> "-" <> Integer.to_string(:erlang.phash2(i), 16)
  end

matched = length(ListScorer.rank(realistic, "harn", key_fn))

ListScorerBench.report(
  "10k realistic items, query \"harn\"",
  ListScorerBench.median_ms(fn ->
    ListScorer.rank(realistic, "harn", key_fn)
  end),
  "(#{matched}/10000 matched; frame budget 16 ms)"
)

all_match =
  for i <- 1..10_000 do
    "session-#{Integer.to_string(i, 16)}-#{:erlang.phash2(i)}-item"
  end

ListScorerBench.report(
  "10k items, every one matches \"session\"",
  ListScorerBench.median_ms(fn ->
    ListScorer.rank(all_match, "session", key_fn)
  end),
  "(pathological ceiling)"
)

long_label = "prefix-match-" <> String.duplicate("x", 1_000_000)
items = ["short-one", long_label, "short-two"]

ListScorerBench.report(
  "one 1,000,000-grapheme label, query \"prefix-match\"",
  ListScorerBench.median_ms(fn ->
    ListScorer.rank(items, "prefix-match", key_fn)
  end),
  "(bounded by @max_score_graphemes)"
)
