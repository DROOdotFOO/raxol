defmodule Raxol.UI.Components.Harness.TextUtil do
  @moduledoc """
  Display-width-aware text truncation and control-byte sanitization shared
  by harness components that ultimately hand model-supplied text to
  `Components.text()`.
  """

  alias Raxol.UI.TextMeasure

  @doc """
  Truncates `text` to `width` display columns, appending a single-cell
  ellipsis when it overflows. Unlike `Raxol.UI.TextLayout.truncate/3`,
  a non-positive or non-integer `width` returns `text` unchanged
  (callers rely on this pass-through).
  """
  @spec truncate_to_width(String.t(), integer()) :: String.t()
  def truncate_to_width(text, width) when is_integer(width) and width > 0 do
    if TextMeasure.display_width(text) <= width do
      text
    else
      {left, _rest} =
        TextMeasure.split_at_display_width(text, max(width - 1, 0))

      left <> "…"
    end
  end

  def truncate_to_width(text, _width), do: text

  # Historical component normalization keeps LF, TAB, and CR. Terminal
  # confinement is stricter at the output sinks; do not use this pattern as
  # the terminal boundary.
  @control_chars_pattern ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{0080}-\x{009F}]/u

  @doc """
  Strips C0/C1 controls and DEL from binary component text, retaining
  `\\n`, `\\t`, and the historical `\\r` behavior encoded by the pattern.
  This is component-level normalization, not the terminal trust boundary:
  terminal emitters use `Raxol.Core.Boundary.TermText`, and the
  paint-authority path uses `Raxol.Harness.Surface.ViewText`.
  """
  @spec sanitize_controls(String.t()) :: String.t()
  def sanitize_controls(text) when is_binary(text),
    do: String.replace(text, @control_chars_pattern, "")
end
