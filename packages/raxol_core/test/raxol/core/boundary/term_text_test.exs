defmodule Raxol.Core.Boundary.TermTextTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Boundary.TermText
  alias Raxol.Core.Boundary.Vectors

  # C0 (minus allow) + DEL + ESC that must never survive with the default allow.
  @default_forbidden Enum.to_list(0x00..0x08) ++
                       [0x0B] ++ Enum.to_list(0x0E..0x1F) ++ [0x7F]

  # ---------------------------------------------------------------------------
  # Shared conformance vectors.
  # ---------------------------------------------------------------------------

  describe "shared vectors" do
    for vector <- Vectors.load("term_text_vectors.json") do
      @vector vector
      test "#{vector["name"]}: #{vector["note"]}" do
        input = Base.decode16!(@vector["input_hex"], case: :lower)
        expected = Base.decode16!(@vector["expect_hex"], case: :lower)
        opts = if @vector["allow"], do: [allow: @vector["allow"]], else: []

        output = TermText.sanitize(input, opts)
        assert output == expected
        refute String.contains?(output, "\e")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Sequence-class coverage.
  # ---------------------------------------------------------------------------

  describe "escape sequence classes" do
    test "CSI (SGR, cursor, private) stripped" do
      assert TermText.sanitize("\e[31mred\e[0m") == "red"
      assert TermText.sanitize("\e[2J\e[Hclean") == "clean"
      assert TermText.sanitize("\e[?1049halt") == "alt"
      assert TermText.sanitize("\e[201~paste") == "paste"
    end

    test "OSC (BEL- and ST-terminated) stripped" do
      assert TermText.sanitize("\e]0;title\aX") == "X"
      assert TermText.sanitize("\e]0;title\e\\X") == "X"
      assert TermText.sanitize("\e]8;;http://evil\e\\text\e]8;;\e\\") == "text"
    end

    test "DCS / APC / PM / SOS stripped" do
      assert TermText.sanitize("\eP1q data\e\\A") == "A"
      assert TermText.sanitize("\e_apc\e\\B") == "B"
      assert TermText.sanitize("\e^pm\e\\C") == "C"
      assert TermText.sanitize("\eXsos\e\\D") == "D"
    end

    test "two-byte ESC forms stripped" do
      assert TermText.sanitize("\ecRIS") == "RIS"
      assert TermText.sanitize("\e=keypad") == "keypad"
    end

    test "truncated trailing ESC stripped" do
      assert TermText.sanitize("tail\e") == "tail"
      assert TermText.sanitize("open\e[") == "open"
      assert TermText.sanitize("osc\e]0;unterminated") == "osc"
    end

    test "double ESC never leaks an ESC" do
      out = TermText.sanitize("\e\e[31mx")
      refute String.contains?(out, "\e")
      assert out == "x"
    end
  end

  describe "control bytes" do
    test "C0 controls stripped except default allow (LF)" do
      assert TermText.sanitize("a\tb\rc\nd") == "abc\nd"
      assert TermText.sanitize("a\0b") == "ab"
    end

    test "allow-list is respected" do
      assert TermText.sanitize("a\tb\nc", allow: [?\t, ?\n]) == "a\tb\nc"
      assert TermText.sanitize("a\tb", allow: [?\t]) == "a\tb"
    end

    test "DEL and raw C1 stripped" do
      assert TermText.sanitize("a\x7Fb") == "ab"
      assert TermText.sanitize(<<?a, 0x85, ?b>>) == "ab"
      assert TermText.sanitize(<<?a, 0xC2, 0x85, ?b>>) == "ab"
    end
  end

  describe "utf-8 handling" do
    test "invalid bytes become U+FFFD" do
      assert TermText.sanitize(<<?a, 0xFF, ?b>>) == "a�b"
      assert TermText.sanitize(<<0xC3, 0x28>>) == "�("
    end

    test "benign / multi-byte text passes through unchanged" do
      assert TermText.sanitize("Hello, world!") == "Hello, world!"
      assert TermText.sanitize("日本語 ✅🚀") == "日本語 ✅🚀"
    end

    test "empty input" do
      assert TermText.sanitize("") == ""
    end

    test "non-binary input never raises" do
      assert TermText.sanitize(nil) == ""
      assert TermText.sanitize(123) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Properties: no ESC, no disallowed control byte, idempotence — for ANY input.
  # ---------------------------------------------------------------------------

  describe "property: output is always safe" do
    test "no ESC and no disallowed control byte survive (default allow)" do
      for _ <- 1..1000 do
        input = :crypto.strong_rand_bytes(:rand.uniform(64))
        out = TermText.sanitize(input)
        bytes = :binary.bin_to_list(out)

        refute 0x1B in bytes, "ESC leaked from #{inspect(input)}"

        for forbidden <- @default_forbidden do
          refute forbidden in bytes,
                 "forbidden byte #{forbidden} leaked from #{inspect(input)}"
        end
      end
    end

    test "C1 control codepoints never survive" do
      # Byte-level 0x80..0x9F is legal inside valid UTF-8 continuation bytes, so
      # this checks decoded CODEPOINTS: no C1 control codepoint may remain.
      for _ <- 1..500 do
        input = :crypto.strong_rand_bytes(:rand.uniform(48))
        out = TermText.sanitize(input)

        for cp <- String.to_charlist(out) do
          refute cp >= 0x80 and cp <= 0x9F, "C1 codepoint #{cp} leaked from #{inspect(input)}"
        end
      end
    end

    test "idempotent" do
      for _ <- 1..500 do
        input = :crypto.strong_rand_bytes(:rand.uniform(64))
        once = TermText.sanitize(input)
        assert TermText.sanitize(once) == once
      end
    end

    test "output is always valid UTF-8" do
      for _ <- 1..500 do
        input = :crypto.strong_rand_bytes(:rand.uniform(64))
        assert String.valid?(TermText.sanitize(input))
      end
    end
  end
end
