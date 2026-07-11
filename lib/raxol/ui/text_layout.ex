defmodule Raxol.UI.TextLayout do
  @moduledoc """
  Canonical text-wrapping entry point implementing the CSS `white-space`
  property (CSS Text Module Level 3) for monospace/terminal text.

  This module unifies the wrapping code that previously lived scattered
  across `Raxol.UI.Components.Input.TextWrapping`,
  `Raxol.UI.Components.Input.TextWrappingCached`, and ad-hoc wrap logic in
  display Components: callers that want CSS-following wrap semantics call
  `wrap/3` with one of the five `white-space` values instead of hand-rolling
  their own collapsing/wrapping loop.

  ## Values

  | Value       | Newlines  | Space/tab collapsing | Wraps at width? |
  |-------------|-----------|------------------------|------------------|
  | `:normal`   | collapse  | collapse               | yes              |
  | `:nowrap`   | collapse  | collapse               | no               |
  | `:pre`      | preserve  | preserve               | no               |
  | `:pre_wrap` | preserve  | preserve               | yes              |
  | `:pre_line` | preserve  | collapse               | yes              |

  `:normal` is the default and is deliberately **bit-identical** to the
  pre-existing `Raxol.UI.Components.Input.TextWrapping.wrap_line_by_word/2`
  behavior (it delegates to it directly) -- including that function's
  pre-existing character-count-based (not display-width-based) line-fit
  check. That means `:normal` is not CJK-width-safe today; this is a known,
  intentionally preserved divergence (see moduledoc note on
  `Raxol.UI.Components.Input.TextWrapping`), not something this module
  fixes, because Phase E of the flex-spec-convergence proposal requires the
  default to match current production output exactly. The other four modes
  are new code and *are* display-width safe via `Raxol.UI.TextMeasure`.

  Word-vs-character break granularity (i.e. CSS `word-break`/`overflow-wrap`)
  is a different, orthogonal axis from `white-space` and is not modeled
  here; `Raxol.UI.Components.Input.TextWrapping.wrap_line_by_char/2` remains
  a separate, untouched utility for that use case.
  """

  alias Raxol.UI.Components.Input.TextWrapping
  alias Raxol.UI.TextLayout.Pretty
  alias Raxol.UI.TextMeasure

  @type white_space :: :normal | :nowrap | :pre | :pre_wrap | :pre_line

  @doc """
  Wraps `text` to `width` display columns according to `white_space`.

  Returns a list of lines (each a `String.t()`). An empty input string
  always yields `[""]` (one empty line), matching how callers such as
  `Raxol.UI.Components.Display.Text` already special-case blank content
  before ever reaching a wrap function.

  A single grapheme wider than `width` is never split -- it is emitted on
  its own line even though it exceeds `width` (this applies to the
  width-aware modes: `:nowrap` is not width-constrained at all, `:pre` is
  never split, and `:normal` also never splits inside a grapheme).
  """
  @spec wrap(String.t(), integer(), white_space()) :: [String.t()]
  def wrap(text, width, white_space \\ :normal)

  def wrap("", _width, _white_space), do: [""]

  def wrap(text, width, :normal) when is_binary(text) and is_integer(width) do
    if width <= 0 do
      [text]
    else
      TextWrapping.wrap_line_by_word(text, width)
    end
  end

  def wrap(text, _width, :nowrap) when is_binary(text) do
    case collapse_whitespace(text) do
      "" -> [""]
      collapsed -> [collapsed]
    end
  end

  def wrap(text, _width, :pre) when is_binary(text) do
    String.split(text, "\n")
  end

  def wrap(text, width, :pre_wrap) when is_binary(text) and is_integer(width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_preserve_segment(&1, width))
  end

  def wrap(text, width, :pre_line) when is_binary(text) and is_integer(width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_collapsed_segment(&1, width))
  end

  @doc """
  `wrap/3` with a CSS `text-wrap` style: `:auto` (greedy, identical to
  `wrap/3`) or `:pretty` (Knuth-Plass DP via `TextLayout.Pretty` —
  minimizes raggedness, avoids single-word orphan lines).

  `:pretty` applies only to `white_space: :normal` (the sole mode where
  break points are freely chosen); other modes ignore it.
  """
  @spec wrap(String.t(), integer(), white_space(), :auto | :pretty) :: [String.t()]
  def wrap(text, width, white_space, :auto), do: wrap(text, width, white_space)

  def wrap("", _width, _white_space, :pretty), do: [""]

  def wrap(text, width, :normal, :pretty)
      when is_binary(text) and is_integer(width) do
    if width <= 0 do
      [text]
    else
      Pretty.wrap(text, width)
    end
  end

  def wrap(text, width, white_space, :pretty), do: wrap(text, width, white_space)

  # --- :pre_wrap: preserve whitespace runs, wrap at width ---

  defp wrap_preserve_segment("", _width), do: [""]

  defp wrap_preserve_segment(segment, width) when width <= 0, do: [segment]

  defp wrap_preserve_segment(segment, width) do
    segment
    |> tokenize_preserve()
    |> do_wrap_preserve(width, "", [])
  end

  defp tokenize_preserve(text) do
    ~r/(\s+)/
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp do_wrap_preserve([], _width, "", acc), do: Enum.reverse(acc)

  defp do_wrap_preserve([], _width, current, acc),
    do: Enum.reverse([current | acc])

  defp do_wrap_preserve([token | rest], width, current, acc) do
    if whitespace_token?(token) do
      do_wrap_preserve_whitespace(token, rest, width, current, acc)
    else
      do_wrap_preserve_word(token, rest, width, current, acc)
    end
  end

  defp do_wrap_preserve_word(token, rest, width, current, acc) do
    cond do
      TextMeasure.display_width(current <> token) <= width ->
        do_wrap_preserve(rest, width, current <> token, acc)

      current != "" ->
        do_wrap_preserve([token | rest], width, "", [current | acc])

      TextMeasure.display_width(token) > width ->
        {chunks, remainder} = split_overlong(token, width)
        do_wrap_preserve(rest, width, remainder, Enum.reverse(chunks) ++ acc)

      true ->
        do_wrap_preserve(rest, width, token, acc)
    end
  end

  # Whitespace is preserved, but (unlike CSS's box-model "hang" allowance,
  # which has no monospace-grid equivalent) it never pushes a line past
  # `width`: if it still fits, it's appended; if it doesn't and the current
  # line already has content, the whitespace is dropped at the wrap point
  # (the line breaks there instead); if the line is empty and even the
  # whitespace alone is overlong (e.g. a long run of tabs), it is
  # force-split like an overlong word.
  defp do_wrap_preserve_whitespace(token, rest, width, current, acc) do
    cond do
      TextMeasure.display_width(current <> token) <= width ->
        do_wrap_preserve(rest, width, current <> token, acc)

      current != "" ->
        do_wrap_preserve(rest, width, "", [current | acc])

      true ->
        {chunks, remainder} = split_overlong(token, width)
        do_wrap_preserve(rest, width, remainder, Enum.reverse(chunks) ++ acc)
    end
  end

  defp whitespace_token?(token), do: token != "" and String.trim(token) == ""

  # --- :pre_line: collapse whitespace within a segment, wrap at width ---

  defp wrap_collapsed_segment(segment, width) do
    wrap_collapsed(collapse_whitespace(segment), width)
  end

  defp wrap_collapsed("", _width), do: [""]
  defp wrap_collapsed(text, width) when width <= 0, do: [text]

  defp wrap_collapsed(text, width) do
    text
    |> String.split(" ")
    |> do_wrap_collapsed(width, "", [])
  end

  defp do_wrap_collapsed([], _width, "", acc), do: Enum.reverse(acc)

  defp do_wrap_collapsed([], _width, current, acc),
    do: Enum.reverse([current | acc])

  defp do_wrap_collapsed([word | rest], width, current, acc) do
    candidate = join_word(current, word)

    cond do
      TextMeasure.display_width(candidate) <= width ->
        do_wrap_collapsed(rest, width, candidate, acc)

      current != "" ->
        do_wrap_collapsed([word | rest], width, "", [current | acc])

      true ->
        do_wrap_collapsed_overlong(word, rest, width, acc)
    end
  end

  defp do_wrap_collapsed_overlong(word, rest, width, acc) do
    if TextMeasure.display_width(word) > width do
      {chunks, remainder} = split_overlong(word, width)
      do_wrap_collapsed(rest, width, remainder, Enum.reverse(chunks) ++ acc)
    else
      do_wrap_collapsed(rest, width, word, acc)
    end
  end

  defp join_word("", word), do: word
  defp join_word(current, word), do: current <> " " <> word

  # --- shared helpers ---

  # Breaks `word` into display-width-bounded chunks. Returns
  # `{full_chunks_in_order, remainder}` where `remainder` fits within
  # `width` and is meant to become the caller's new in-progress line. Never
  # splits a grapheme in half; if a single grapheme is wider than `width`
  # it is emitted alone (the documented exception to the width bound).
  defp split_overlong(word, width) do
    do_split_overlong(word, width, [])
  end

  defp do_split_overlong("", _width, chunks), do: {Enum.reverse(chunks), ""}

  defp do_split_overlong(word, width, chunks) do
    if TextMeasure.display_width(word) <= width do
      {Enum.reverse(chunks), word}
    else
      {chunk, rest} = split_one_overlong_chunk(word, width)
      do_split_overlong(rest, width, [chunk | chunks])
    end
  end

  # Splits one width-bounded chunk off the front of `word`. Falls back to
  # force-taking a single grapheme when `width` is narrower than the
  # widest single grapheme in `word` (so we always make progress).
  defp split_one_overlong_chunk(word, width) do
    case TextMeasure.split_at_display_width(word, width) do
      {"", _rest} ->
        case String.next_grapheme(word) do
          {grapheme, rest} -> {grapheme, rest}
          nil -> {word, ""}
        end

      {left, rest} ->
        {left, rest}
    end
  end

  defp collapse_whitespace(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # --- text-overflow: single-line truncation -----------------------------

  @ellipsis "…"

  @doc """
  Truncates a single line to `width` display columns per CSS
  `text-overflow` (`:ellipsis`) or a plain hard clip (`:clip`).

  Never splits a double-width grapheme in half -- the cut always lands one
  column earlier instead. Output display width is always `<= width`.

  - `:clip` -- hard cut at `width`, no indicator appended.
  - `:ellipsis` -- cut to make room for a trailing single-cell `"…"`
    (U+2026 HORIZONTAL ELLIPSIS). At `width == 1` the whole line collapses
    to just the ellipsis character.

  `width <= 0` always yields `""`. A line that already fits within `width`
  is returned unchanged (no ellipsis appended, even in `:ellipsis` mode).
  """
  @spec truncate(String.t(), integer(), :ellipsis | :clip) :: String.t()
  def truncate(line, width, mode)
      when is_binary(line) and is_integer(width) and mode in [:ellipsis, :clip] do
    cond do
      width <= 0 -> ""
      TextMeasure.display_width(line) <= width -> line
      mode == :clip -> clip_to_width(line, width)
      mode == :ellipsis -> fit_with_ellipsis(line, width)
    end
  end

  defp clip_to_width(line, width) do
    {left, _rest} = TextMeasure.split_at_display_width(line, width)
    left
  end

  # Assumes `width >= 1` (callers guard `width <= 0` separately).
  defp fit_with_ellipsis(_line, width) when width <= 1, do: @ellipsis

  defp fit_with_ellipsis(line, width) do
    {left, _rest} = TextMeasure.split_at_display_width(line, width - 1)
    left <> @ellipsis
  end

  # --- line-clamp: multi-line block truncation ----------------------------

  @doc """
  Wraps `text` to `width` columns (per `white_space`, default `:normal`)
  and keeps at most `max_lines` lines, implementing CSS Overflow Module
  Level 4 `line-clamp`.

  If wrapping produces `max_lines` or fewer lines, the result is returned
  unchanged -- no ellipsis is added when nothing was actually clamped.

  If wrapping produces more lines than `max_lines`, the excess lines are
  dropped and the kept last line gets a block-ellipsis: a trailing
  single-cell `"…"` is appended, re-truncating that line first if
  appending it would push the line past `width`. The block-ellipsed line's
  display width never exceeds `width`.

  `max_lines <= 0` yields `[]`.

  ## Options

  - `:white_space` -- one of `Raxol.UI.TextLayout.white_space/0`, default
    `:normal`.
  """
  @spec clamp(String.t(), integer(), integer(), keyword()) :: [String.t()]
  def clamp(text, width, max_lines, opts \\ [])

  def clamp(text, width, max_lines, opts) when is_integer(max_lines) do
    if max_lines <= 0 do
      []
    else
      white_space = Keyword.get(opts, :white_space, :normal)
      lines = wrap(text, width, white_space)

      if length(lines) <= max_lines do
        lines
      else
        lines
        |> Enum.take(max_lines)
        |> List.update_at(-1, &block_ellipsis(&1, width))
      end
    end
  end

  defp block_ellipsis(_line, width) when width <= 0, do: ""

  defp block_ellipsis(line, width) do
    if TextMeasure.display_width(line) + 1 <= width do
      line <> @ellipsis
    else
      fit_with_ellipsis(line, width)
    end
  end
end
