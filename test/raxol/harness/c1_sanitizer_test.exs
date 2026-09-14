defmodule Raxol.Harness.C1SanitizerTest do
  # Regression for the C1 control-byte gap (issue #616): both render-path
  # sanitizers used a byte-wise `>= 0x20` allowlist that let the 8-bit C1
  # controls (U+0080..U+009F) through raw -- the siblings of the ESC-led
  # sequences they otherwise neutralize. On a terminal honoring 8-bit C1,
  # `0x9B` is CSI and `0x9D` is OSC, so raw C1 in agent-authored content was a
  # live injection vector at the footer / picker / transcript-search surfaces.
  use ExUnit.Case, async: true

  alias Raxol.UI.Rendering.PaintAuthority.ContentGuard
  alias Raxol.Harness.Surface.ViewText

  defp has_c1?(bin) do
    bin |> :binary.bin_to_list() |> Enum.any?(&(&1 >= 0x80 and &1 <= 0x9F))
  end

  describe "ContentGuard.sanitize_line/1 strips C1 controls" do
    test "raw 8-bit C1 CSI/OSC/IND are removed" do
      for c1 <- [0x9B, 0x9D, 0x90, 0x84, 0x85] do
        out = ContentGuard.sanitize_line(<<c1, "2J">>)

        refute has_c1?(out),
               "raw C1 #{inspect(c1, base: :hex)} survived: #{inspect(out)}"
      end
    end

    test "UTF-8-encoded C1 (0xC2 0x9B) is removed" do
      out = ContentGuard.sanitize_line(<<0xC2, 0x9B, "2J">>)
      refute has_c1?(out)
      assert out == "2J"
    end

    test "SGR is still preserved verbatim" do
      assert ContentGuard.sanitize_line(<<0x1B, "[1;31mhi", 0x1B, "[0m">>) ==
               <<0x1B, "[1;31mhi", 0x1B, "[0m">>
    end

    test "ESC-led CSI is still neutralized to visible residue" do
      assert ContentGuard.sanitize_line(<<0x1B, "[2J">>) == "[2J"
    end

    test "legitimate multi-byte UTF-8 text is preserved (incl. a 0x80-range continuation byte)" do
      # U+00E9 (e-acute) and U+0840 (Mandaic letter, whose 3rd byte is 0x80).
      text = <<0xC3, 0xA9, 0xE0, 0xA1, 0x80, "abc">>
      assert ContentGuard.sanitize_line(text) == text
    end
  end

  describe "ViewText plain lines strip C1 controls" do
    defp plain(content) do
      %{type: :text, content: content, style: %{}}
      |> ViewText.lines(80, :plain)
      |> Enum.map_join("", fn
        {c, _style} -> c
        c when is_binary(c) -> c
      end)
    end

    test "raw and UTF-8 C1 do not reach the wire" do
      refute has_c1?(plain(<<"before", 0x9B, "2J", "after">>))
      refute has_c1?(plain(<<"x", 0xC2, 0x9D, "0;title", 0x07>>))
    end

    test "printable and multi-byte UTF-8 survive" do
      assert plain("hello world") == "hello world"
      assert plain(<<0xC3, 0xA9>>) == <<0xC3, 0xA9>>
    end
  end

  # Trojan Source (CWE-451): a bidi override needs no control byte to make a
  # rendered line say the opposite of what it contains, so a filter that only
  # removes C0/C1/DEL leaves the deception intact. Every caller of
  # `sanitize_line/1` is rendering text it did not author.
  describe "ViewText.sanitize_line/1 strips bidi and zero-width format characters" do
    test "the bidi overrides and isolates are removed" do
      for cp <- [
            0x202A,
            0x202B,
            0x202C,
            0x202D,
            0x202E,
            0x2066,
            0x2067,
            0x2068,
            0x2069
          ] do
        out = ViewText.sanitize_line("a" <> <<cp::utf8>> <> "b")

        assert out == "ab",
               "U+#{Integer.to_string(cp, 16)} survived: #{inspect(out)}"
      end
    end

    test "zero-width space, soft hyphen, marks, separators and BOM are removed" do
      for cp <- [0x00AD, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029, 0xFEFF] do
        out = ViewText.sanitize_line("a" <> <<cp::utf8>> <> "b")

        assert out == "ab",
               "U+#{Integer.to_string(cp, 16)} survived: #{inspect(out)}"
      end
    end

    test "a hosted-session notice cannot be reversed by an RLO" do
      forged = "disabled" <> <<0x202E::utf8>> <> "delbane"

      assert ViewText.sanitize_line(forged) == "disableddelbane"
    end

    test "joiners and ordinary text are kept" do
      # ZWJ/ZWNJ are content, not formatting: stripping them would split
      # emoji families and corrupt Indic and Perso-Arabic text.
      assert ViewText.sanitize_line("a\tb") == "a\tb"
      assert ViewText.sanitize_line("日本語") == "日本語"
      assert ViewText.sanitize_line("مرحبا") == "مرحبا"
      assert ViewText.sanitize_line("👨‍👩‍👧") == "👨‍👩‍👧"

      assert ViewText.sanitize_line("क्" <> <<0x200C::utf8>> <> "ष") ==
               "क्" <> <<0x200C::utf8>> <> "ष"
    end
  end
end
