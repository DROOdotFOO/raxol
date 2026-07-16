defmodule Raxol.UI.ListScorer do
  @moduledoc """
  General-purpose fuzzy list scorer: `(list, query, key_fn) -> ranked`.

  This is a **list-item** scorer -- it ranks arbitrary terms (session
  structs, block refs, action descriptors, file paths, ...) by how well an
  arbitrary `key_fn`-derived label matches a query string. It is
  deliberately *not* `Raxol.Search.Fuzzy`: that module searches character
  cells inside a rendered terminal buffer (`Buffer.t()`, `{x, y}`
  positions) -- a different category of problem (buffer-cell search vs.
  list-item ranking) that happens to share the word "fuzzy". Folding this
  into `Search.Fuzzy` would conflate the two.

  Used by `Raxol.UI.Components.Harness.Picker` (the overlay picker
  primitive, AD-U3) and any future "pick one of N" projection (palette,
  session picker, jump-to-block, file mentions -- F2's eventual sources).

  ## Algorithm

  An fzf-style Smith-Waterman-lite subsequence aligner: every query
  grapheme must appear in the key, in order (not necessarily contiguous),
  but the *scoring* rewards:

    * **adjacency** -- consecutive matched characters score higher than
      the same characters scattered across the key (a gap penalty
      accumulates for each skipped character between two matches);
    * **word boundaries** -- a match at the start of the string, right
      after a separator (space/`-`/`_`/`/`/`.`/`:`/etc.), or at a
      lowercase-to-uppercase transition (`camelCase`) scores a bonus;
    * **position** -- an earlier match in the key scores slightly higher
      than a later one, all else equal.

  Matching is case-insensitive by default (`case_sensitive: true` opts
  out). Unicode-aware: works over `String.graphemes/1`, not bytes or
  codepoints, so multi-codepoint graphemes (combining marks, some emoji)
  and CJK text are handled as single units -- `positions` in the result
  are grapheme indices into `key`, safe to feed to
  `Raxol.UI.TextMeasure` for display-column highlighting (CJK graphemes
  are double-width; a byte or codepoint index would misalign).

  ## Result ordering

  Results are sorted score descending, ties broken by original list
  order (a stable sort made explicit via an `{-score, original_index}`
  sort key, rather than relying on the underlying sort's stability).
  Items with no subsequence match are excluded entirely. An empty query
  matches everything with score `0.0` in original order (no filtering).

  ## Performance

  Every item pays a fixed per-keystroke cost (grapheme-splitting +
  case-folding its `key_fn` label, then a cheap two-pointer subsequence
  check) regardless of whether it matches; only items that pass the
  subsequence check pay the O(query length * key length) DP. This is a
  *pure, stateless* function -- it re-derives each item's grapheme
  representation on every call rather than caching it, so a caller
  filtering the same 10k-item list on every keystroke (a picker) is
  paying that fixed cost 10k times per keystroke no matter how the DP
  itself is tuned. Measured on a realistic corpus (varied labels, most
  of which a multi-character query rejects before the DP), 10k items
  comfortably clear the 16ms/keystroke target; a degenerate corpus
  where literally every item matches (which fuzzy filtering exists to
  make rare) costs meaningfully more since the DP then runs for all
  10,000 items -- see `list_scorer_test.exs`'s `performance` tests for
  both numbers. A caller that must guarantee 16ms against a large list
  on every keystroke under adversarial data should cache each item's
  grapheme split alongside the item (invalidated when the item list
  changes) rather than re-deriving it here every call; that's a
  caller-side concern, not this module's, since `rank/4`'s contract is
  a pure function of its arguments.
  """

  @type result :: %{
          item: term(),
          key: String.t(),
          score: float(),
          positions: [non_neg_integer()]
        }

  @type opt :: {:case_sensitive, boolean()}

  # Base score for every matched character.
  @match_base 10.0
  # Bonus for a match that starts a "word" (string start, after a
  # separator, or a lowercase->uppercase / non-letter->letter transition).
  @bonus_boundary 6.0
  # Bonus for a match immediately following the previous match (zero gap).
  @bonus_consecutive 8.0
  # Penalty per skipped character between two matches.
  @gap_penalty 1.0
  # Scale of the "earlier is better" position bonus (applied once per
  # matched character, proportional to how early in the key it lands).
  @position_bonus_scale 2.0

  # Sentinel for "no valid alignment ends here" -- large enough that no
  # legitimate combination of bonuses/penalties over realistic string
  # lengths could approach it, so `> @neg_inf / 2` reliably tells finite
  # scores apart from unreachable cells without a tagged sum type.
  @neg_inf -1.0e9

  # Caps the grapheme list actually fed to `subsequence?/2` and `align/3`
  # per item, independent of how long an adversarial `key_fn` label is.
  # Without this, a single absurdly long label (an unbounded paste, a
  # log line used as a list key, ...) makes the O(query length * key
  # length) DP -- and the two-pointer subsequence pre-check -- cost
  # proportional to that label's full length on every keystroke. The
  # clamp also keeps the `@gap_penalty` accumulation (`advance/5`'s
  # decaying running max) well under `@neg_inf / 2` regardless of key
  # length, so a long label can no longer be misclassified `:no_match`
  # by the sentinel-comparison coupling described above `@neg_inf`.
  # `key:` in the result is still the full untruncated label (positions
  # are indices into this prefix, which are valid prefix indices into
  # the full key too) -- only a match lying entirely past the cap is
  # missed, an fzf-acceptable tradeoff.
  @max_score_graphemes 1024
  # Byte budget for the pre-split prefix slice (see `bounded_key_prefix/1`).
  # 4 bytes/grapheme covers every single-codepoint UTF-8 grapheme (the
  # max encoded width of one codepoint); multi-codepoint clusters
  # (combining marks, some emoji ZWJ sequences) can in principle need
  # more bytes per grapheme, in which case the clamp bites a little
  # earlier than exactly `@max_score_graphemes` graphemes -- an
  # acceptable variant of the same "match past the cap is missed"
  # tradeoff, not a correctness bug.
  @max_key_bytes @max_score_graphemes * 4

  @doc """
  Ranks `items` against `query`, using `key_fn.(item)` to derive each
  item's searchable/display label (a `String.t()`).

  Options:

    * `:case_sensitive` -- defaults to `false`.

  Returns a list of `%{item:, key:, score:, positions:}` maps, sorted
  score-descending with original order as the tiebreak. Items whose key
  does not contain `query` as a subsequence are dropped. An empty query
  returns every item, in original order, with `score: 0.0` and
  `positions: []`.
  """
  @spec rank([term()], String.t(), (term() -> String.t()), [opt()]) :: [
          result()
        ]
  def rank(items, query, key_fn, opts \\ [])

  def rank(items, "", key_fn, _opts) do
    Enum.map(items, fn item ->
      %{item: item, key: key_fn.(item), score: 0.0, positions: []}
    end)
  end

  def rank(items, query, key_fn, opts) do
    case_sensitive = Keyword.get(opts, :case_sensitive, false)
    query_graphemes = normalize_string_graphemes(query, case_sensitive)

    items
    |> Enum.with_index()
    |> Enum.reduce([], fn {item, index}, acc ->
      case score_item(item, index, key_fn, query_graphemes, case_sensitive) do
        nil -> acc
        result -> [result | acc]
      end
    end)
    |> Enum.sort_by(fn r -> {-r.score, r.index} end)
    |> Enum.map(&Map.delete(&1, :index))
  end

  # `nil` when the key doesn't contain `query_graphemes` as a subsequence
  # (the cheap two-pointer check runs first and rejects the common case
  # without paying for the O(query * key) DP below -- this is what keeps
  # 10k-item filtering fast: most items get discarded right here).
  defp score_item(item, index, key_fn, query_graphemes, case_sensitive) do
    key = key_fn.(item)

    {raw_key_graphemes, norm_key_graphemes} =
      key
      |> bounded_key_prefix()
      |> key_graphemes(case_sensitive)
      |> clamp_key_graphemes()

    if subsequence?(query_graphemes, norm_key_graphemes) do
      build_result(
        item,
        index,
        key,
        query_graphemes,
        norm_key_graphemes,
        raw_key_graphemes
      )
    else
      nil
    end
  end

  defp build_result(
         item,
         index,
         key,
         query_graphemes,
         norm_key_graphemes,
         raw_key_graphemes
       ) do
    case align(query_graphemes, norm_key_graphemes, raw_key_graphemes) do
      {:ok, score, positions} ->
        %{
          item: item,
          key: key,
          score: score,
          positions: positions,
          index: index
        }

      :no_match ->
        nil
    end
  end

  defp normalize_string_graphemes(text, true), do: String.graphemes(text)

  defp normalize_string_graphemes(text, false),
    do: String.graphemes(String.downcase(text))

  # Returns `{raw_graphemes, normalized_graphemes}` for a key. `raw` feeds
  # boundary/camelCase detection (which needs real casing); `normalized`
  # feeds matching (case-folded unless `case_sensitive`).
  #
  # `String.graphemes/1`'s general Unicode grapheme-cluster algorithm is
  # the single biggest cost in this module on the 10k-item bench (it
  # dominates even the DP scoring). Most real keys here -- session ids,
  # file paths, command names -- are pure ASCII (one byte per codepoint,
  # no combining marks), where grapheme clusters are trivially single
  # bytes; `byte_size(text) == String.length(text)` cheaply detects that
  # case and a plain byte-list walk replaces the general algorithm
  # (measured ~4x faster end to end). Genuinely multi-byte/combining text
  # (CJK, accents, emoji) falls back to the correct, slower path.
  defp key_graphemes(key, case_sensitive) do
    if byte_size(key) == String.length(key) do
      ascii_key_graphemes(key, case_sensitive)
    else
      unicode_key_graphemes(key, case_sensitive)
    end
  end

  # Bounds the *input* to `key_graphemes/2` before it ever splits into
  # graphemes, so an adversarially long key (a million-character label)
  # never pays for a full grapheme split just to have the result
  # discarded by `clamp_key_graphemes/1` below -- `:binary.part/3`
  # produces a sub-binary reference in O(1) (no copy), so this is cheap
  # regardless of the original key's length.
  defp bounded_key_prefix(key) when byte_size(key) <= @max_key_bytes, do: key

  defp bounded_key_prefix(key),
    do: key |> :binary.part(0, @max_key_bytes) |> trim_to_valid_utf8()

  # A raw byte-count slice of UTF-8 text can land mid-codepoint; back off
  # one byte at a time (at most 3 iterations, the max UTF-8 sequence
  # width) until the slice is valid again.
  defp trim_to_valid_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_to_valid_utf8(:binary.part(bin, 0, byte_size(bin) - 1))
    end
  end

  # See `@max_score_graphemes`. Applied to both lists post-hoc (rather
  # than short-circuiting the split above) so the clamp lives in exactly
  # one place regardless of which of `key_graphemes/2`'s four branches
  # produced the lists.
  defp clamp_key_graphemes({raw, norm}) do
    {Enum.take(raw, @max_score_graphemes),
     Enum.take(norm, @max_score_graphemes)}
  end

  defp ascii_key_graphemes(key, true) do
    raw = for(<<c <- key>>, do: <<c>>)
    {raw, raw}
  end

  defp ascii_key_graphemes(key, false) do
    {raw_rev, down_rev} =
      Enum.reduce(:binary.bin_to_list(key), {[], []}, fn c,
                                                         {raw_acc, down_acc} ->
        {[<<c>> | raw_acc], [<<ascii_downcase_byte(c)>> | down_acc]}
      end)

    {Enum.reverse(raw_rev), Enum.reverse(down_rev)}
  end

  defp ascii_downcase_byte(c) when c in ?A..?Z, do: c + 32
  defp ascii_downcase_byte(c), do: c

  defp unicode_key_graphemes(key, true) do
    raw = String.graphemes(key)
    {raw, raw}
  end

  defp unicode_key_graphemes(key, false) do
    raw = String.graphemes(key)
    downcased = String.graphemes(String.downcase(key))

    norm =
      if length(downcased) == length(raw) do
        downcased
      else
        Enum.map(raw, &String.downcase/1)
      end

    {raw, norm}
  end

  defp subsequence?([], _key), do: true
  defp subsequence?(_query, []), do: false

  defp subsequence?([q | qrest], [q | krest]), do: subsequence?(qrest, krest)
  defp subsequence?(query, [_k | krest]), do: subsequence?(query, krest)

  # -- alignment DP (fzf-style Smith-Waterman-lite) --
  #
  # Builds one row per query character, each row a K-element list of
  # scores (K = key length) via a single left-to-right pass with O(1)
  # amortized bookkeeping (a decaying running max standing in for
  # "best predecessor ending at any earlier position, gap-penalized").
  # Parent pointers ride alongside for backtracking the winning
  # alignment's positions once the last row is built.
  #
  # Deliberately list-only, no tuples: every access this DP needs --
  # walking the key, the previous row, and the per-position static bonus
  # -- is sequential (never random), so plain list pattern-matching
  # recursion (fastest primitive access pattern on the BEAM) replaces
  # `elem/2` tuple indexing everywhere except the O(Q) (not O(Q*K))
  # backtrack step, where `Enum.at/2` on a ~30-element list is negligible.
  # Single-grapheme query fast path: this is the broadest possible match
  # (the first keystroke into an empty picker commonly matches a large
  # fraction of a big list), so it's worth skipping the general Q-row DP
  # machinery entirely -- a single-character match has no adjacency/gap
  # history to track (there's no previous match to be consecutive with,
  # exactly like the general algorithm's `first_row?` branch), so the
  # winning position is just "the matching key position with the
  # highest static bonus," found in one linear scan.
  defp align([qchar], key_graphemes, raw_key_graphemes) do
    static_bonus_list =
      static_bonus_list(raw_key_graphemes, length(key_graphemes))

    case best_single_match(key_graphemes, static_bonus_list, qchar, 0, nil) do
      nil -> :no_match
      {j, score} -> {:ok, score, [j]}
    end
  end

  defp align(query_graphemes, key_graphemes, raw_key_graphemes) do
    key_len = length(key_graphemes)
    static_bonus_list = static_bonus_list(raw_key_graphemes, key_len)

    rows =
      query_graphemes
      |> Enum.with_index()
      |> Enum.map_reduce(nil, fn {qchar, i}, prev_row ->
        first_row? = i == 0

        {row, parents} =
          build_row(
            qchar,
            key_graphemes,
            static_bonus_list,
            prev_row,
            first_row?
          )

        {{row, parents}, row}
      end)
      |> elem(0)

    {last_row, _} = List.last(rows)

    case best_end(last_row) do
      nil -> :no_match
      {best_j, best_score} -> {:ok, best_score, backtrack(rows, best_j)}
    end
  end

  # Boundary/position bonuses depend only on the key (not on which query
  # row is being scored), so they're computed exactly once per item here
  # instead of once per (query char, key position) cell -- the
  # difference between O(K) and O(Q*K) work per item. `prev` is threaded
  # through the recursion (the previous list element) rather than
  # indexed, so boundary detection never needs random access either.
  defp static_bonus_list(raw_key_graphemes, key_len) do
    denom = max(key_len - 1, 1)
    step = @position_bonus_scale / denom
    build_static_bonus(raw_key_graphemes, nil, 0, step)
  end

  defp build_static_bonus([], _prev, _j, _step), do: []

  defp build_static_bonus([cur | rest], prev, j, step) do
    boundary = if boundary?(j, prev, cur), do: @bonus_boundary, else: 0.0
    position = @position_bonus_scale - step * j
    bonus = @match_base + boundary + position
    [bonus | build_static_bonus(rest, cur, j + 1, step)]
  end

  defp boundary?(0, _prev, _cur), do: true

  defp boundary?(_j, prev, cur),
    do: separator?(prev) or camel_boundary?(prev, cur)

  # ASCII fast path (byte-pattern match, no regex engine dispatch) with a
  # regex fallback for non-ASCII graphemes -- measured over an order of
  # magnitude faster than routing every grapheme through `Regex.match?/2`
  # on the 10k-item bench, which matters here because this runs once per
  # key position.
  defp separator?(<<c>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9,
    do: false

  defp separator?(<<_c>>), do: true
  defp separator?(grapheme), do: grapheme =~ ~r/^[^\p{L}\p{N}]$/u

  defp camel_boundary?(prev, cur), do: lower?(prev) and upper?(cur)

  defp lower?(<<c>>) when c in ?a..?z, do: true
  defp lower?(<<c>>) when c in ?A..?Z or c in ?0..?9, do: false
  defp lower?(g), do: g =~ ~r/^\p{Ll}$/u

  defp upper?(<<c>>) when c in ?A..?Z, do: true
  defp upper?(<<c>>) when c in ?a..?z or c in ?0..?9, do: false
  defp upper?(g), do: g =~ ~r/^\p{Lu}$/u

  # Walks `key_graphemes`, `static_bonus_list`, and (when not the first
  # row) `prev_row` all in lockstep, one position `j` at a time. Returns
  # `{row, parents}` in natural left-to-right order (built via cons on
  # the way back up the recursion, no reverse needed).
  defp build_row(qchar, key_graphemes, static_bonus_list, prev_row, first_row?) do
    build_row(
      qchar,
      key_graphemes,
      static_bonus_list,
      prev_row,
      first_row?,
      0,
      @neg_inf,
      -1
    )
  end

  defp build_row(_qchar, [], [], _prev_row, _first_row?, _j, _bp, _src),
    do: {[], []}

  defp build_row(
         qchar,
         [k | k_rest],
         [static | static_rest],
         prev_row,
         first_row?,
         j,
         bp,
         src
       ) do
    {bp, src, prev_row_rest} = advance(j, prev_row, first_row?, bp, src)

    {h, p} =
      if k == qchar do
        consecutive? = not first_row? and src == j - 1
        bonus = static + if consecutive?, do: @bonus_consecutive, else: 0.0
        score_of(bonus, bp, src, first_row?)
      else
        {@neg_inf, -1}
      end

    {row_rest, par_rest} =
      build_row(
        qchar,
        k_rest,
        static_rest,
        prev_row_rest,
        first_row?,
        j + 1,
        bp,
        src
      )

    {[h | row_rest], [p | par_rest]}
  end

  defp score_of(bonus, _bp, _src, true), do: {bonus, -1}

  defp score_of(_bonus, bp, _src, false) when bp <= @neg_inf / 2,
    do: {@neg_inf, -1}

  defp score_of(bonus, bp, src, false), do: {bonus + bp, src}

  # Decaying running max: bp(j) = max(bp(j-1) - gap_penalty, H_prev[j-1]).
  # H_prev[j-1] is the "zero-gap" candidate (end the previous match
  # exactly at j-1, so this match at j is consecutive); the decayed
  # carry-forward is the "some gap already accumulated" candidate. Ties
  # favor the fresh (consecutive) candidate. `prev_row` is consumed one
  # element per call starting at j=1 (H_prev[0] first), so by
  # construction its head is always H_prev[j-1] when this runs.
  defp advance(_j, prev_row, true, bp, src), do: {bp, src, prev_row}
  defp advance(0, prev_row, false, bp, src), do: {bp, src, prev_row}

  defp advance(j, [fresh | rest], false, bp, src) do
    decayed = bp - @gap_penalty

    if fresh >= decayed do
      {fresh, j - 1, rest}
    else
      {decayed, src, rest}
    end
  end

  # Linear scan for the Q=1 fast path in `align/3`: the best-scoring key
  # position equal to `qchar`, using each position's precomputed static
  # bonus directly as its score (no predecessor/gap tracking needed --
  # equivalent to the general algorithm's `first_row?` scoring).
  defp best_single_match([], [], _qchar, _j, best), do: best

  defp best_single_match([k | k_rest], [static | static_rest], qchar, j, best) do
    next_best =
      cond do
        k != qchar -> best
        best == nil -> {j, static}
        static > elem(best, 1) -> {j, static}
        true -> best
      end

    best_single_match(k_rest, static_rest, qchar, j + 1, next_best)
  end

  defp best_end(row) do
    row
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {score, j}, acc ->
      cond do
        score <= @neg_inf / 2 -> acc
        acc == nil -> {j, score}
        score > elem(acc, 1) -> {j, score}
        true -> acc
      end
    end)
  end

  # Backtracks from the winning final-row position through each row's
  # parent pointers to recover the matched key position for every query
  # character, in query order (position for query char 1, 2, ..., Q).
  # `Enum.at/2` here is O(row length) but only runs once per row (O(Q)
  # total), negligible next to the O(Q*K) `build_row` pass above.
  defp backtrack(rows, best_j) do
    {positions, _last_parent} =
      rows
      |> Enum.reverse()
      |> Enum.reduce({[], best_j}, fn {_row, parents}, {acc, j} ->
        {[j | acc], Enum.at(parents, j)}
      end)

    positions
  end
end
