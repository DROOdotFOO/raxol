defmodule Raxol.Speech.TTS.Sanitize do
  @moduledoc """
  Text sanitization for TTS backends.

  Strips C0/C1 control characters that would otherwise be passed to a
  command-line TTS process. Preserves printable text, tabs, and newlines.
  Useful when implementing a custom `Raxol.Speech.TTS.Backend` so all
  backends share the same input contract.
  """

  # Strip control characters but keep tabs (\t) and newlines (\n).
  # The class covers \x00-\x08, \x0B, \x0C, \x0E-\x1F, and \x7F (DEL).
  @control_chars ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

  @doc """
  Removes C0/C1 control characters from `text`.

  Returns the input verbatim when it contains no control characters.
  """
  @spec strip_control_chars(String.t()) :: String.t()
  def strip_control_chars(text) when is_binary(text) do
    String.replace(text, @control_chars, "")
  end
end
