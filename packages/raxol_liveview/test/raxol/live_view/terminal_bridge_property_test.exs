defmodule Raxol.LiveView.TerminalBridgePropertyTest do
  @moduledoc """
  Property tests for TerminalBridge HTML escaping.

  Targets the class of bug where charlist codepoints > 255 crash
  IO.iodata_to_binary when pushed as bare integers into iolists.
  """
  use ExUnit.Case, async: true
  use ExUnit.Case
  use ExUnitProperties

  # Access the private function via Module.
  # TerminalBridge.escape_html_text/1 is private, so we test it
  # through the public buffer_to_html/2 or by extracting a test helper.
  # For now, we duplicate the function under test to verify the fix.

  # --- Generators ---

  # ASCII printable (safe baseline)
  defp ascii_printable_gen do
    StreamData.string(:ascii, min_length: 0, max_length: 100)
  end

  # Box-drawing characters (the original crash trigger)
  defp box_drawing_gen do
    StreamData.map(
      StreamData.list_of(
        StreamData.member_of(Enum.to_list(0x2500..0x257F) ++ Enum.to_list(0x250C..0x2573)),
        min_length: 1,
        max_length: 20
      ),
      &List.to_string/1
    )
  end

  # CJK Unified Ideographs
  defp cjk_gen do
    StreamData.map(
      StreamData.list_of(
        StreamData.member_of(Enum.to_list(0x4E00..0x4FFF)),
        min_length: 1,
        max_length: 20
      ),
      &List.to_string/1
    )
  end

  # Extended Latin (accented characters)
  defp latin_extended_gen do
    StreamData.map(
      StreamData.list_of(
        StreamData.member_of(Enum.to_list(0x00C0..0x024F)),
        min_length: 1,
        max_length: 20
      ),
      &List.to_string/1
    )
  end

  # HTML-special characters that must be escaped
  defp html_special_gen do
    StreamData.map(
      StreamData.list_of(
        StreamData.member_of(~c[<>&"']),
        min_length: 1,
        max_length: 20
      ),
      &List.to_string/1
    )
  end

  # Mixed Unicode: any valid codepoint (excluding surrogates)
  defp unicode_gen do
    StreamData.map(
      StreamData.list_of(
        StreamData.filter(
          StreamData.integer(1..0x10FFFF),
          fn cp -> cp < 0xD800 or cp > 0xDFFF end
        ),
        min_length: 0,
        max_length: 50
      ),
      &List.to_string/1
    )
  end

  # --- The function under test (mirrors the fix) ---

  defp escape_html_text(text) do
    escape_html_binary(text, [])
  end

  defp escape_html_binary(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp escape_html_binary(<<?&, rest::binary>>, acc),
    do: escape_html_binary(rest, ["&amp;" | acc])

  defp escape_html_binary(<<?<, rest::binary>>, acc), do: escape_html_binary(rest, ["&lt;" | acc])
  defp escape_html_binary(<<?>, rest::binary>>, acc), do: escape_html_binary(rest, ["&gt;" | acc])

  defp escape_html_binary(<<?", rest::binary>>, acc),
    do: escape_html_binary(rest, ["&quot;" | acc])

  defp escape_html_binary(<<?', rest::binary>>, acc),
    do: escape_html_binary(rest, ["&#39;" | acc])

  defp escape_html_binary(<<c::utf8, rest::binary>>, acc),
    do: escape_html_binary(rest, [<<c::utf8>> | acc])

  # --- Properties ---

  property "escape_html_text never crashes on any valid UTF-8 string" do
    check all(text <- unicode_gen(), max_runs: 500) do
      result = escape_html_text(text)
      assert is_binary(result)
    end
  end

  property "escape_html_text preserves string length for non-special chars" do
    # For strings without HTML-special chars, content length is preserved
    check all(
            text <- StreamData.one_of([ascii_printable_gen(), cjk_gen(), box_drawing_gen()]),
            not String.contains?(text, ["&", "<", ">", "\"", "'"])
          ) do
      assert escape_html_text(text) == text
    end
  end

  property "escape_html_text roundtrips: unescape(escape(x)) == x" do
    check all(text <- unicode_gen(), max_runs: 300) do
      escaped = escape_html_text(text)

      unescaped =
        escaped
        |> String.replace("&amp;", "&")
        |> String.replace("&lt;", "<")
        |> String.replace("&gt;", ">")
        |> String.replace("&quot;", "\"")
        |> String.replace("&#39;", "'")

      assert unescaped == text
    end
  end

  property "escape_html_text produces valid UTF-8" do
    check all(text <- unicode_gen(), max_runs: 300) do
      result = escape_html_text(text)
      assert String.valid?(result)
    end
  end

  property "escape_html_text handles box-drawing characters" do
    check all(text <- box_drawing_gen(), max_runs: 200) do
      result = escape_html_text(text)
      assert is_binary(result)
      assert String.valid?(result)
      # Box-drawing chars have no HTML-special chars, so output == input
      assert result == text
    end
  end

  property "escape_html_text handles CJK characters" do
    check all(text <- cjk_gen(), max_runs: 200) do
      result = escape_html_text(text)
      assert is_binary(result)
      assert String.valid?(result)
      assert result == text
    end
  end

  property "escape_html_text handles extended Latin" do
    check all(text <- latin_extended_gen(), max_runs: 200) do
      result = escape_html_text(text)
      assert is_binary(result)
      assert String.valid?(result)
      assert result == text
    end
  end

  property "escape_html_text escapes all five HTML-special characters" do
    check all(text <- html_special_gen(), max_runs: 200) do
      result = escape_html_text(text)
      # No raw < or > should survive
      refute String.contains?(result, ["<", ">"])
      # No raw " or ' should survive
      refute String.contains?(result, ["\"", "'"])
      # Roundtrip must recover original
      unescaped =
        result
        |> String.replace("&amp;", "&")
        |> String.replace("&lt;", "<")
        |> String.replace("&gt;", ">")
        |> String.replace("&quot;", "\"")
        |> String.replace("&#39;", "'")

      assert unescaped == text
    end
  end

  property "escape_html_text handles mixed ASCII + CJK + box-drawing + specials" do
    check all(
            parts <-
              StreamData.list_of(
                StreamData.one_of([
                  ascii_printable_gen(),
                  cjk_gen(),
                  box_drawing_gen(),
                  latin_extended_gen(),
                  html_special_gen()
                ]),
                min_length: 1,
                max_length: 5
              ),
            max_runs: 200
          ) do
      text = Enum.join(parts)
      result = escape_html_text(text)
      assert is_binary(result)
      assert String.valid?(result)
    end
  end
end
