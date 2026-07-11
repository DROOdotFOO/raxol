defmodule Raxol.UI.TextLayout.Pretty do
  @moduledoc """
  `text-wrap: pretty` -- a Knuth-Plass-style dynamic program for the
  monospace grid.

  Greedy wrapping (`text-wrap: auto`) packs each line until the next token
  would overflow, which frequently produces one long "orphan" word alone on
  the final line while earlier lines run needlessly close to the container
  edge. This module instead considers every legal way to break a paragraph
  into lines and picks the one that minimizes total raggedness (squared
  slack) plus an orphan penalty, subject to the hard constraint that no line
  may exceed `width` (a single token wider than `width` is force-broken and
  is the only permitted exception).

  Break opportunities are a UAX #14 subset appropriate for monospace
  terminal text:

    * at a run of whitespace (the whitespace is consumed by the break)
    * immediately after a hyphen-minus (`-`) inside a word
    * immediately after every CJK ideograph / kana grapheme (CJK text can
      break between any two ideographs)

  All display-width math goes through `Raxol.UI.TextMeasure` so CJK/emoji
  double-width cells are accounted for correctly; this module never uses
  `String.length/1` for layout decisions.

  This module is pure (same input always produces the same output) and
  self-contained: it does not depend on `Raxol.UI.TextLayout` or any other
  layout module. Callers are responsible for caching if needed.
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

  def wrap(text, width, opts) when is_binary(text) and is_integer(width) and width > 0 do
    text
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&wrap_paragraph(&1, width, opts))
  end

  def wrap(_text, width, _opts) when is_integer(width) do
    raise ArgumentError, "width must be a positive integer, got: #{inspect(width)}"
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
        word_tokens = tokenize_word(part, word_id)
        {word_id + 1, Enum.reverse(word_tokens) ++ tokens}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp whitespace?(part), do: String.trim(part) == ""

  @spec tokenize_word(String.t(), non_neg_integer()) :: [token()]
  defp tokenize_word(word, word_id) do
    {buffer, tokens} =
      word
      |> String.graphemes()
      |> Enum.reduce({[], []}, fn grapheme, {buffer, tokens} ->
        cond do
          cjk_grapheme?(grapheme) ->
            tokens = flush_buffer(buffer, word_id, tokens)

            cjk = %{
              text: grapheme,
              width: TextMeasure.display_width(grapheme),
              kind: :cjk,
              word_id: word_id
            }

            {[], [cjk | tokens]}

          grapheme == "-" ->
            text = buffer |> Enum.reverse() |> Enum.join() |> Kernel.<>("-")

            piece = %{
              text: text,
              width: TextMeasure.display_width(text),
              kind: :hyphen_piece,
              word_id: word_id
            }

            {[], [piece | tokens]}

          true ->
            {[grapheme | buffer], tokens}
        end
      end)

    buffer
    |> flush_buffer(word_id, tokens)
    |> Enum.reverse()
  end

  defp flush_buffer([], _word_id, tokens), do: tokens

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
      [cp | _] -> Enum.any?(@cjk_ranges, fn {lo, hi} -> cp >= lo and cp <= hi end)
      _ -> false
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
  defp breakable_kind?(kind), do: kind in [:space, :cjk, :hyphen_piece, :split_piece]

  @spec dp_wrap([token()], pos_integer(), keyword()) :: [String.t()]
  defp dp_wrap([], _width, _opts), do: [""]

  defp dp_wrap(tokens, width, opts) do
    n = length(tokens)
    tokens_t = List.to_tuple(tokens)
    prefix = build_prefix(tokens)
    breaks = legal_breaks(tokens_t, n)
    breaks_t = List.to_tuple(breaks)
    m = tuple_size(breaks_t)

    total_words =
      tokens
      |> Enum.map(& &1.word_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    orphan_threshold = Keyword.get(opts, :orphan_threshold, @default_orphan_threshold)
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
      fallback_wrap(tokens_t, n)
    else
      breaks_t
      |> backtrack(prevs, m - 1)
      |> build_lines(tokens_t)
    end
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
    init_costs = 0 |> then(&Tuple.duplicate(:infinity, m) |> put_elem(0, &1))
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

  defp consider_transition(breaks_t, jdx, idx, costs, is_last, ctx, {best_cost, best_prev} = acc) do
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
    orphan_cost(ctx.tokens_t, start_idx, end_idx, ctx.total_words, ctx.orphan_penalty, ctx.orphan_threshold)
  end

  defp orphan_cost(tokens_t, start_idx, end_idx, total_words, penalty, threshold) do
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
      start_idx = g_start
      end_idx = end_index(tokens_t, g_end)

      if end_idx < start_idx do
        ""
      else
        start_idx..end_idx
        |> Enum.map_join("", &elem(tokens_t, &1).text)
      end
    end)
  end

  defp fallback_wrap(tokens_t, n) do
    0..(n - 1)
    |> Enum.map(&elem(tokens_t, &1))
    |> Enum.reject(&(&1.kind == :space))
    |> Enum.map(& &1.text)
  end
end
