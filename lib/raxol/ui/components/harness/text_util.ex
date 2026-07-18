defmodule Raxol.UI.Components.Harness.TextUtil do
  @moduledoc """
  Display-width-aware text truncation shared by harness components.

  Truncates `text` to `width` display columns, appending a single-cell
  ellipsis when it overflows. Unlike `Raxol.UI.TextLayout.truncate/3`,
  a non-positive or non-integer `width` returns `text` unchanged
  (callers rely on this pass-through).
  """

  alias Raxol.UI.TextMeasure

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
end
