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

  # `\n` and `\t` are the only control characters ever meaningful in
  # rendered harness text, so both are kept; everything else in C0
  # (`0x00-0x1F` minus those two), DEL (`0x7F`), and C1 (`0x80-0x9F`) is
  # removed.
  @control_chars_pattern ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{0080}-\x{009F}]/u

  @doc """
  Strips every C0/C1 control byte, DEL, and ESC from `text` except `\\n`
  and `\\t`. The single trust boundary for control-byte stripping shared by
  every harness component that hands model-supplied text (tool args,
  approval referents, message bodies, ...) to `Components.text()` --
  callers must route untrusted text through this rather than duplicating
  the pattern, so an embedded ESC/OSC sequence can never reach the
  terminal renderer disguised as real content.
  """
  @spec sanitize_controls(String.t()) :: String.t()
  def sanitize_controls(text) when is_binary(text),
    do: String.replace(text, @control_chars_pattern, "")
end
