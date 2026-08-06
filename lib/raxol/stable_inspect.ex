defmodule Raxol.StableInspect do
  @moduledoc """
  Version-stable string quoting for golden artifacts.

  `inspect/1`'s string escaping tracks the host Elixir release (1.18 started
  printing zero-width and special-whitespace codepoints as `\\uXXXX`), so a
  golden serialized with it drifts across CI's Elixir matrix even though the
  render is identical. `Raxol.RATE` and `Raxol.Harness.Surface.Parity` both
  pin cross-version artifacts, so their serializers use this frozen escape
  table instead: byte-for-byte the 1.18+ `inspect/1` output for printable
  strings (the encoding the committed artifacts already contain), emitted
  identically on every supported release.

  The table mirrors `Code.Identifier.escape_char/2` as of Elixir 1.18:
  printable codepoints stay literal, the "confusing invisibles" become
  `\\uXXXX`, control characters use their short escapes, and anything else
  falls back to `\\xNN`. Unlike `inspect/1`, a non-printable string is still
  quoted (escaped byte by byte) rather than shown as `<<...>>` -- a stricter
  rule, and one that cannot vary by release.
  """

  # The 1.18+ "confusing invisibles": BOM, mathematical invisibles, bidi
  # controls, interlinear annotations, joiners, zero-width and no-break
  # spaces, line separators, and the fixed-width space block.
  defguardp invisible?(char)
            when char == 0xFEFF or
                   char in 0x2061..0x2064 or
                   char in [0x061C, 0x200E, 0x200F] or
                   char in 0x202A..0x202E or
                   char in 0x2066..0x2069 or
                   char in 0xFFF9..0xFFFC or
                   char in [0x200C, 0x200D, 0x034F] or
                   char in [0x00A0, 0x200B, 0x2060] or
                   char in [0x2028, 0x2029] or
                   char in 0x2000..0x200A or
                   char == 0x205F

  @doc "Quote and escape `text` identically on every supported Elixir."
  @spec quoted(String.t()) :: String.t()
  def quoted(text) when is_binary(text),
    do: <<?", escape_text(text, <<>>)::binary, ?">>

  defp escape_text(<<>>, acc), do: acc

  defp escape_text(<<?", rest::binary>>, acc),
    do: escape_text(rest, <<acc::binary, "\\\"">>)

  defp escape_text(<<"\#{", rest::binary>>, acc),
    do: escape_text(rest, <<acc::binary, "\\\#{">>)

  defp escape_text(<<char::utf8, rest::binary>>, acc),
    do: escape_text(rest, <<acc::binary, escape_char(char)::binary>>)

  defp escape_text(<<byte, rest::binary>>, acc),
    do: escape_text(rest, <<acc::binary, "\\x", hex(byte, 2)::binary>>)

  defp escape_char(?\0), do: "\\0"
  defp escape_char(?\a), do: "\\a"
  defp escape_char(?\b), do: "\\b"
  defp escape_char(?\d), do: "\\d"
  defp escape_char(?\e), do: "\\e"
  defp escape_char(?\f), do: "\\f"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(?\v), do: "\\v"
  defp escape_char(?\\), do: "\\\\"

  defp escape_char(char) when invisible?(char), do: "\\u" <> hex(char, 4)

  defp escape_char(char)
       when char in 0x20..0x7E
       when char in 0xA0..0xD7FF
       when char in 0xE000..0xFFFD
       when char in 0x10000..0x10FFFF,
       do: <<char::utf8>>

  defp escape_char(char) when char < 0x100, do: "\\x" <> hex(char, 2)
  defp escape_char(char), do: "\\x{" <> hex(char, 4) <> "}"

  defp hex(value, digits) do
    value
    |> Integer.to_string(16)
    |> String.pad_leading(digits, "0")
  end
end
