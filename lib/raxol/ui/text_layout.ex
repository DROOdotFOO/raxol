defmodule Raxol.UI.TextLayout do
  @moduledoc """
  Canonical text-wrapping entry point implementing the CSS `white-space`
  property (CSS Text Module Level 3) for monospace/terminal text. Call
  `wrap/3` with one of the five values below instead of hand-rolling
  collapsing/wrapping logic.

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
    cond do
      whitespace_token?(token) ->
        # Whitespace is preserved and always attaches to the current line
        # (approximates CSS's allowance for trailing whitespace to "hang"
        # past the wrap point rather than force an extra line break).
        do_wrap_preserve(rest, width, current <> token, acc)

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

      TextMeasure.display_width(word) > width ->
        {chunks, remainder} = split_overlong(word, width)
        do_wrap_collapsed(rest, width, remainder, Enum.reverse(chunks) ++ acc)

      true ->
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
      case TextMeasure.split_at_display_width(word, width) do
        {"", _rest} ->
          # width is narrower than the widest single grapheme in `word`;
          # force-take one grapheme so we always make progress.
          {grapheme, rest} =
            case String.next_grapheme(word) do
              {g, r} -> {g, r}
              nil -> {word, ""}
            end

          do_split_overlong(rest, width, [grapheme | chunks])

        {left, rest} ->
          do_split_overlong(rest, width, [left | chunks])
      end
    end
  end

  defp collapse_whitespace(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
