defmodule Raxol.UI.TextLayout.Pretty do
  @moduledoc """
  `text-wrap: pretty` -- a Knuth-Plass-style dynamic program for the
  monospace grid.

  Unlike greedy wrapping (packs each line until the next token overflows,
  often stranding one "orphan" word on the final line), this considers
  every legal way to break a paragraph and picks the one minimizing total
  raggedness (squared slack) plus an orphan penalty, subject to no line
  exceeding `width` (a single overlong token is force-broken).

  Break opportunities (UAX #14 subset): whitespace runs, after a
  hyphen-minus inside a word, and between any two CJK ideographs/kana.

  All display-width math goes through `Raxol.UI.TextMeasure` (never
  `String.length/1`). Pure and self-contained -- no dependency on
  `Raxol.UI.TextLayout`; callers cache if needed.
  """

  alias Raxol.UI.TextMeasure

  @type token_kind :: :word | :space | :cjk | :hyphen_piece | :split_piece

  @type token :: %{
          text: String.t(),
          width: non_neg_integer(),
          kind: token_kind(),
          word_id: non_neg_integer() | nil
        }

  @default_orphan_threshold 2
  @default_badness_exponent 2

  # `run_dp` is O(m^2) in legal break-point count `m` (every candidate line
  # end considers every earlier candidate start). Ordinary prose paragraphs
  # keep `m` in the low hundreds at most, but a single CJK line has one
  # breakable token per ideograph, so a long newline-free CJK line (e.g. a
  # streamed LLM response with no line breaks) can push `m` into the tens
  # of thousands -- `m^2` there is billions of iterations on ONE call.
  # Above this ceiling `dp_wrap` skips the DP and packs the paragraph with
  # an O(m) greedy pass instead (`greedy_wrap/4`): same "never exceed
  # width except the single-overlong-token exception" guarantee, just
  # without the DP's raggedness-minimizing line choice. 600^2 (360k) stays
  # comfortably sub-millisecond, and ordinary paragraphs are almost always
  # far under 600 break points, so this only engages on the pathological
  # inputs it exists for.
  @max_dp_breaks 600

  @doc """
  Wraps `text` to `width` display columns using the pretty (Knuth-Plass-style)
  algorithm.

  Paragraphs (separated by `"\\n"`) are wrapped independently and their
  resulting lines concatenated in order. A blank paragraph produces a single
  empty line, so the number of `"\\n"`-delimited input paragraphs is a lower
  bound on the number of output lines.

  ## Options

    * `:orphan_penalty` - integer cost added when a paragraph's last line
      would contain a single word while the paragraph has more than
      `:orphan_threshold` words total. Defaults to `width * width`.
    * `:orphan_threshold` - word count above which the orphan penalty
      applies. Defaults to `2` (i.e. the penalty applies once a paragraph
      has more than 2 words).
    * `:badness_exponent` - exponent used in the raggedness cost
      `abs(width - line_width) ** exponent`. Defaults to `2`. An exponent of
      `0` makes every non-perfect line cost `1`, which degenerates the DP
      toward "minimize line count" (useful as a greedy-ish reference).
  """
  @spec wrap(String.t(), pos_integer()) :: [String.t()]
  @spec wrap(String.t(), pos_integer(), keyword()) :: [String.t()]
  def wrap(text, width, opts \\ [])

  def wrap(text, width, opts)
      when is_binary(text) and is_integer(width) and width > 0 do
    text
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&wrap_paragraph(&1, width, opts))
  end

  def wrap(_text, width, _opts) when is_integer(width) do
    raise ArgumentError,
          "width must be a positive integer, got: #{inspect(width)}"
  end

  # -- Paragraph wrapping -----------------------------------------------------

  @spec wrap_paragraph(String.t(), pos_integer(), keyword()) :: [String.t()]
  defp wrap_paragraph(paragraph, width, opts) do
    trimmed = String.trim(paragraph)

    if trimmed == "" do
      [""]
    else
      trimmed
      |> tokenize()
      |> force_split_wide(width)
      |> dp_wrap(width, opts)
    end
  end

  # -- Tokenization -------------------------------------------------------

  @cjk_ranges [
    # Hiragana
    {0x3040, 0x309F},
    # Katakana
    {0x30A0, 0x30FF},
    # CJK Unified Ideographs Extension A
    {0x3400, 0x4DBF},
    # CJK Unified Ideographs
    {0x4E00, 0x9FFF},
    # CJK Compatibility Ideographs
    {0xF900, 0xFAFF}
  ]

  @spec tokenize(String.t()) :: [token()]
  defp tokenize(text) do
    ~r/(\s+)/u
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce({0, []}, fn part, {word_id, tokens} ->
      if whitespace?(part) do
        token = %{text: " ", width: 1, kind: :space, word_id: nil}
        {word_id, [token | tokens]}
      else
        {word_tokens, next_word_id} = tokenize_word(part, word_id)
        {next_word_id, Enum.reverse(word_tokens) ++ tokens}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp whitespace?(part), do: String.trim(part) == ""

  # Returns `{tokens, next_word_id}`.
  #
  # Each CJK grapheme is its OWN word, not a fragment of the surrounding
  # whitespace-delimited run. `word_id` exists only to feed the last-line
  # orphan rule ("does this line end with a single dangling word?"), and
  # CJK has no spaces -- a whole CJK paragraph is one whitespace-run, so
  # numbering it as one word made EVERY candidate last line a 1-word line.
  # The orphan penalty (`width * width`) then fired on every layout, and
  # the DP bought its way out with absurd raggedness: for a 48-cell CJK
  # line in a 38-cell budget it chose 11/37 over the available 38/10.
  # Hyphen pieces deliberately keep sharing one id -- leaving "known"
  # alone off "well-known" IS a real orphan.
  @spec tokenize_word(String.t(), non_neg_integer()) ::
          {[token()], non_neg_integer()}
  defp tokenize_word(word, word_id) do
    {buffer, tokens, next_id} =
      word
      |> String.graphemes()
      |> Enum.reduce({[], [], word_id}, fn grapheme, {buffer, tokens, id} ->
        cond do
          cjk_grapheme?(grapheme) ->
            {tokens, id} = flush_buffer_with_id(buffer, id, tokens)

            cjk = %{
              text: grapheme,
              width: TextMeasure.display_width(grapheme),
              kind: :cjk,
              word_id: id
            }

            {[], [cjk | tokens], id + 1}

          grapheme == "-" ->
            text = buffer |> Enum.reverse() |> Enum.join() |> Kernel.<>("-")

            piece = %{
              text: text,
              width: TextMeasure.display_width(text),
              kind: :hyphen_piece,
              word_id: id
            }

            {[], [piece | tokens], id}

          true ->
            {[grapheme | buffer], tokens, id}
        end
      end)

    {tokens, next_id} = flush_buffer_with_id(buffer, next_id, tokens)

    {Enum.reverse(tokens), next_id + 1}
  end

  # Flushes a pending run of non-CJK graphemes as one `:word` token,
  # consuming an id only when there was something to flush.
  defp flush_buffer_with_id([], word_id, tokens), do: {tokens, word_id}

  defp flush_buffer_with_id(buffer, word_id, tokens),
    do: {flush_buffer(buffer, word_id, tokens), word_id + 1}

  defp flush_buffer(buffer, word_id, tokens) do
    text = buffer |> Enum.reverse() |> Enum.join()

    token = %{
      text: text,
      width: TextMeasure.display_width(text),
      kind: :word,
      word_id: word_id
    }

    [token | tokens]
  end

  defp cjk_grapheme?(grapheme) do
    case String.to_charlist(grapheme) do
      [cp | _] ->
        Enum.any?(@cjk_ranges, fn {lo, hi} -> cp >= lo and cp <= hi end)

      _ ->
        false
    end
  end

  # -- Force-splitting overlong tokens ---------------------------------------

  # A single :word or :hyphen_piece token whose width exceeds the container
  # is broken into grapheme-safe pieces via TextMeasure. :cjk tokens are
  # already single graphemes and cannot be split further; if a CJK grapheme
  # itself is wider than `width` it is the permitted "single overlong token"
  # exception to the hard width constraint.
  @spec force_split_wide([token()], pos_integer()) :: [token()]
  defp force_split_wide(tokens, width) do
    Enum.flat_map(tokens, fn
      %{kind: kind, width: w, text: text, word_id: word_id}
      when kind in [:word, :hyphen_piece] and w > width ->
        split_into_pieces(text, width, word_id)

      token ->
        [token]
    end)
  end

  defp split_into_pieces(text, width, word_id),
    do: split_into_pieces(text, width, word_id, [])

  defp split_into_pieces("", _width, _word_id, acc), do: Enum.reverse(acc)

  defp split_into_pieces(text, width, word_id, acc) do
    {piece, rest} =
      case TextMeasure.split_at_display_width(text, width) do
        {"", _right} ->
          # Even a single grapheme doesn't fit (e.g. a double-width
          # grapheme against width=1). Force-take it alone; this is the
          # unavoidable "single token wider than width" exception.
          {grapheme, remainder} = String.next_grapheme(text)
          {grapheme, remainder}

        {left, right} ->
          {left, right}
      end

    token = %{
      text: piece,
      width: TextMeasure.display_width(piece),
      kind: :split_piece,
      word_id: word_id
    }

    split_into_pieces(rest, width, word_id, [token | acc])
  end

  # -- Dynamic program --------------------------------------------------------

  # `kind`s after which a line break is legally allowed.
  defp breakable_kind?(kind),
    do: kind in [:space, :cjk, :hyphen_piece, :split_piece]

  @spec dp_wrap([token()], pos_integer(), keyword()) :: [String.t()]
  defp dp_wrap([], _width, _opts), do: [""]

  defp dp_wrap(tokens, width, opts) do
    n = length(tokens)
    tokens_t = List.to_tuple(tokens)
    prefix = build_prefix(tokens)
    breaks = legal_breaks(tokens_t, n)
    breaks_t = List.to_tuple(breaks)
    m = tuple_size(breaks_t)

    if m > @max_dp_breaks do
      greedy_wrap(tokens_t, prefix, breaks_t, m, width)
    else
      dp_wrap_within_ceiling(tokens, tokens_t, prefix, breaks_t, m, width, opts)
    end
  end

  defp dp_wrap_within_ceiling(
         tokens,
         tokens_t,
         prefix,
         breaks_t,
         m,
         width,
         opts
       ) do
    total_words =
      tokens
      |> Enum.map(& &1.word_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    orphan_threshold =
      Keyword.get(opts, :orphan_threshold, @default_orphan_threshold)

    orphan_penalty = Keyword.get(opts, :orphan_penalty, width * width)
    exponent = Keyword.get(opts, :badness_exponent, @default_badness_exponent)

    ctx = %{
      tokens_t: tokens_t,
      prefix: prefix,
      width: width,
      exponent: exponent,
      orphan_penalty: orphan_penalty,
      orphan_threshold: orphan_threshold,
      total_words: total_words
    }

    {costs, prevs} = run_dp(breaks_t, m, ctx)

    if elem(costs, m - 1) == :infinity do
      # Should be unreachable given tokenization guarantees (every token is
      # individually <= width after force-splitting, and every token is
      # adjacent to at least one legally-breakable neighbor). Fall back to a
      # single-token-per-line split so callers never crash on pathological
      # input (e.g. mixed-script tokens not covered by the break rules).
      fallback_wrap(tokens_t, tuple_size(tokens_t))
    else
      breaks_t
      |> backtrack(prevs, m - 1)
      |> build_lines(tokens_t)
    end
  end

  # O(m) greedy line pack, used above `@max_dp_breaks`: pack tokens onto
  # the current line until the next legal break would overflow `width`,
  # then cut there -- classic greedy word-wrap (no raggedness
  # minimization, no last-line orphan handling; those are the DP's job).
  #
  # Scans `breaks_t` with two indices that each only move forward, so the
  # whole paragraph costs O(m) rather than the DP's O(m^2): `jdx` is the
  # break the current line starts at, `idx` is the next candidate break
  # being tested to extend it.
  defp greedy_wrap(tokens_t, prefix, breaks_t, m, width) do
    greedy_break_indices(tokens_t, prefix, breaks_t, m, width, 0, 1, [0])
    |> Enum.map(&elem(breaks_t, &1))
    |> build_lines(tokens_t)
  end

  defp greedy_break_indices(
         _tokens_t,
         _prefix,
         _breaks_t,
         m,
         _width,
         _jdx,
         idx,
         acc
       )
       when idx >= m do
    Enum.reverse([m - 1 | acc])
  end

  defp greedy_break_indices(tokens_t, prefix, breaks_t, m, width, jdx, idx, acc) do
    start_idx = elem(breaks_t, jdx)
    end_idx = end_index(tokens_t, elem(breaks_t, idx))

    if greedy_line_fits?(prefix, start_idx, end_idx, width) do
      greedy_break_indices(
        tokens_t,
        prefix,
        breaks_t,
        m,
        width,
        jdx,
        idx + 1,
        acc
      )
    else
      # `idx` overflows the line started at `jdx` -- cut at `idx - 1`
      # instead and start the next line there. `idx - 1 > jdx` always
      # holds here: two ADJACENT legal breaks (`idx == jdx + 1`) bound
      # exactly one token between them (by construction of
      # `legal_breaks/2` -- a break exists only right after a breakable
      # token, and `:word` tokens, the only non-breakable kind, never sit
      # adjacent to each other), so that span is always
      # `greedy_line_fits?` regardless of width (see its single-token
      # clause) -- overflow is only ever detected once at least one break
      # has already been accepted since `jdx`, guaranteeing progress.
      new_jdx = idx - 1

      greedy_break_indices(tokens_t, prefix, breaks_t, m, width, new_jdx, idx, [
        new_jdx | acc
      ])
    end
  end

  # A candidate line from `start_idx` to `end_idx` (token indices,
  # inclusive) "fits" when: it is degenerate (`end_idx < start_idx`, all
  # content between the two breaks was a single dropped space -- treated
  # as a non-boundary so the scan just keeps extending through it rather
  # than forcing an empty line); OR it is a single token (`end_idx ==
  # start_idx`, always accepted regardless of width -- the same "one
  # overlong token stands alone" exception `force_split_wide` and the
  # DP's `line_cost` both rely on); OR its display width is within
  # `width`.
  defp greedy_line_fits?(prefix, start_idx, end_idx, width) do
    end_idx <= start_idx or
      elem(prefix, end_idx + 1) - elem(prefix, start_idx) <= width
  end

  defp build_prefix(tokens) do
    [0 | Enum.scan(tokens, 0, fn t, acc -> acc + t.width end)]
    |> List.to_tuple()
  end

  defp legal_breaks(_tokens_t, 0), do: [0]

  defp legal_breaks(tokens_t, n) do
    interior =
      if n < 2 do
        []
      else
        for g <- 1..(n - 1), breakable_kind?(elem(tokens_t, g - 1).kind), do: g
      end

    [0] ++ interior ++ [n]
  end

  defp run_dp(breaks_t, m, ctx) do
    init_costs = 0 |> then(&(Tuple.duplicate(:infinity, m) |> put_elem(0, &1)))
    init_prevs = Tuple.duplicate(nil, m)

    Enum.reduce(1..(m - 1), {init_costs, init_prevs}, fn idx, {costs, prevs} ->
      is_last = idx == m - 1

      {best_cost, best_prev} =
        Enum.reduce(0..(idx - 1), {:infinity, nil}, fn jdx, acc ->
          consider_transition(breaks_t, jdx, idx, costs, is_last, ctx, acc)
        end)

      {put_elem(costs, idx, best_cost), put_elem(prevs, idx, best_prev)}
    end)
  end

  defp consider_transition(
         breaks_t,
         jdx,
         idx,
         costs,
         is_last,
         ctx,
         {best_cost, best_prev} = acc
       ) do
    prev_cost = elem(costs, jdx)

    if prev_cost == :infinity do
      acc
    else
      case line_cost(breaks_t, jdx, idx, ctx, is_last) do
        :invalid ->
          acc

        cost ->
          total = prev_cost + cost

          if better?(total, best_cost) do
            {total, jdx}
          else
            {best_cost, best_prev}
          end
      end
    end
  end

  defp better?(_a, :infinity), do: true
  defp better?(a, b), do: a < b

  defp line_cost(breaks_t, jdx, idx, ctx, is_last) do
    start_idx = elem(breaks_t, jdx)
    end_idx = end_index(ctx.tokens_t, elem(breaks_t, idx))

    if end_idx < start_idx do
      :invalid
    else
      line_width = elem(ctx.prefix, end_idx + 1) - elem(ctx.prefix, start_idx)
      token_count = end_idx - start_idx + 1

      if line_width > ctx.width and token_count > 1 do
        :invalid
      else
        compute_cost(ctx, start_idx, end_idx, line_width, is_last)
      end
    end
  end

  defp compute_cost(ctx, _start_idx, _end_idx, line_width, false) do
    diff = abs(ctx.width - line_width)
    pow_int(diff, ctx.exponent)
  end

  defp compute_cost(ctx, start_idx, end_idx, _line_width, true) do
    orphan_cost(
      ctx.tokens_t,
      start_idx,
      end_idx,
      ctx.total_words,
      ctx.orphan_penalty,
      ctx.orphan_threshold
    )
  end

  defp orphan_cost(
         tokens_t,
         start_idx,
         end_idx,
         total_words,
         penalty,
         threshold
       ) do
    word_ids =
      start_idx..end_idx
      |> Enum.map(&elem(tokens_t, &1).word_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if length(word_ids) == 1 and total_words > threshold do
      penalty
    else
      0
    end
  end

  defp pow_int(0, _exp), do: 0
  defp pow_int(_diff, 0), do: 1
  defp pow_int(diff, exp), do: Integer.pow(diff, exp)

  # Given a legal break gap `g` (the boundary immediately before token index
  # `g`), returns the index of the last token INCLUDED in the line that ends
  # at this gap. A gap caused by a :space token drops that space (it belongs
  # to neither line); any other breakable kind is kept on the earlier line.
  defp end_index(_tokens_t, 0), do: -1

  defp end_index(tokens_t, g) do
    case elem(tokens_t, g - 1).kind do
      :space -> g - 2
      _ -> g - 1
    end
  end

  defp backtrack(breaks_t, prevs, idx), do: backtrack(breaks_t, prevs, idx, [])

  defp backtrack(breaks_t, _prevs, 0, acc), do: [elem(breaks_t, 0) | acc]

  defp backtrack(breaks_t, prevs, idx, acc) do
    prev_idx = elem(prevs, idx)
    backtrack(breaks_t, prevs, prev_idx, [elem(breaks_t, idx) | acc])
  end

  defp build_lines(break_gaps, tokens_t) do
    break_gaps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [g_start, g_end] ->
      start_idx = drop_leading_space(tokens_t, g_start, g_end)
      end_idx = end_index(tokens_t, g_end)

      if end_idx < start_idx do
        ""
      else
        start_idx..end_idx
        |> Enum.map_join("", &elem(tokens_t, &1).text)
      end
    end)
  end

  # `end_index/2` drops the space at a break only when the break gap is
  # ITSELF a space token. A break after a `:cjk` (or `:hyphen_piece`)
  # token strands any following space at the head of the next line -- so a
  # CJK/latin mix such as "...斜体 italic," wrapped between 体 and the
  # space rendered the next line as " italic,", indented by one column and
  # one column narrower than its budget. Whitespace at the head of a
  # wrapped line is never wanted in `:normal` mode; the modes that do
  # preserve whitespace never reach this function.
  defp drop_leading_space(tokens_t, start_idx, g_end) do
    if start_idx < g_end and elem(tokens_t, start_idx).kind == :space do
      drop_leading_space(tokens_t, start_idx + 1, g_end)
    else
      start_idx
    end
  end

  defp fallback_wrap(tokens_t, n) do
    0..(n - 1)
    |> Enum.map(&elem(tokens_t, &1))
    |> Enum.reject(&(&1.kind == :space))
    |> Enum.map(& &1.text)
  end
end
