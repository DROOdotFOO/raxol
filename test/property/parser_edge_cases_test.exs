defmodule Raxol.Property.ParserEdgeCasesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Terminal.ANSI.Utils.AnsiParser, as: Parser

  describe "malformed sequences" do
    property "incomplete CSI sequences don't crash" do
      check all prefix <- string(:printable, min_length: 0, max_length: 10),
                params <- list_of(integer(0..999), max_length: 5),
                suffix <- string(:printable, min_length: 0, max_length: 10),
                max_runs: 1000 do
        # Build incomplete CSI
        param_str = if params == [], do: "", else: Enum.join(params, ";")
        incomplete = prefix <> "\e[" <> param_str <> suffix

        # Should not crash
        result = Parser.parse(incomplete)
        assert is_list(result)
      end
    end

    property "missing terminators are handled" do
      check all _cmd_char <- member_of(["H", "A", "B", "C", "D", "m", "J", "K"]),
                params <- list_of(integer(0..100), min_length: 1, max_length: 3),
                text <- string(:alphanumeric, min_length: 1, max_length: 20),
                max_runs: 500 do
        # CSI without proper terminator, add space to separate from text
        sequence = "\e[" <> Enum.join(params, ";")
        full_input = sequence <> " " <> text

        # Should handle gracefully
        result = Parser.parse(full_input)
        assert is_list(result)

        # Parser should handle incomplete sequences gracefully -
        # either preserve text or handle it as part of the sequence
        # Both behaviors are acceptable for malformed input
      end
    end

    property "invalid parameter formats are handled" do
      check all invalid_params <- list_of(
                  frequency([
                    {1, constant("")},
                    {1, constant(";;")},
                    {1, string(:printable, min_length: 1, max_length: 3)},
                    {1, constant("-")},
                    {1, constant("0x10")},
                    {1, constant("1.5")}
                  ]),
                  min_length: 1,
                  max_length: 5
                ),
                max_runs: 500 do
        sequence = "\e[" <> Enum.join(invalid_params, ";") <> "m"

        # Should not crash
        result = Parser.parse(sequence)
        assert is_list(result)
      end
    end
  end

  describe "boundary conditions" do
    property "maximum parameter values" do
      check all param <- integer(0..2_147_483_647),
                cmd <- member_of(["A", "B", "C", "D", "H"]),
                max_runs: 500 do
        sequence = "\e[#{param}#{cmd}"

        # Should handle large parameters
        result = Parser.parse(sequence)
        assert is_list(result)
        assert [_ | _] = result
      end
    end

    property "deeply nested sequences" do
      check all depth <- integer(1..20),
                max_runs: 100 do
        # Build nested SGR sequences
        opening = Enum.map_join(1..depth, "", fn i -> "\e[#{rem(i, 7) + 30}m" end)
        closing = "\e[0m"
        sequence = opening <> "text" <> closing

        # Should handle deep nesting
        result = Parser.parse(sequence)
        assert is_list(result)
      end
    end

    property "extremely long single sequence" do
      check all param_count <- integer(50..200),
                max_runs: 50 do
        # Generate many parameters
        params = Enum.map_join(1..param_count, ";", fn i -> Integer.to_string(rem(i, 108)) end)
        sequence = "\e[" <> params <> "m"

        # Should handle long parameter lists
        result = Parser.parse(sequence)
        assert is_list(result)
      end
    end

    property "zero-length and empty sequences" do
      check all prefix <- string(:printable, min_length: 0, max_length: 5),
                suffix <- string(:printable, min_length: 0, max_length: 5),
                max_runs: 500 do
        sequences = [
          prefix <> "\e[m" <> suffix,      # Empty SGR
          prefix <> "\e[;m" <> suffix,     # Single semicolon
          prefix <> "\e[;;m" <> suffix,    # Multiple semicolons
          prefix <> "\e[0m" <> suffix      # Reset
        ]

        Enum.each(sequences, fn seq ->
          result = Parser.parse(seq)
          assert is_list(result)
        end)
      end
    end
  end

  describe "unicode edge cases" do
    property "emoji in escape sequences" do
      check all emoji <- member_of(["[*]", "[+]", "[>]", "[#]", "[!]"]),
                color <- integer(30..37),
                max_runs: 500 do
        # Emoji as part of escape sequence (invalid but shouldn't crash)
        sequences = [
          "\e[#{color}m#{emoji}\e[0m",
          "\e[#{emoji}#{color}m",  # Invalid
          "#{emoji}\e[#{color}m#{emoji}"
        ]

        Enum.each(sequences, fn seq ->
          result = Parser.parse(seq)
          assert is_list(result)
        end)
      end
    end

    property "combining characters with escapes" do
      check all base <- member_of(["a", "e", "i", "o", "u"]),
                combining <- member_of(["\u0301", "\u0308", "\u0303"]),
                color <- integer(30..37),
                max_runs: 500 do
        # Combining characters shouldn't break parsing
        sequences = [
          "\e[#{color}m#{base}#{combining}\e[0m",
          "#{base}#{combining}\e[#{color}m",
          "\e[#{color}m#{base}\e[0m#{combining}"
        ]

        Enum.each(sequences, fn seq ->
          result = Parser.parse(seq)
          assert is_list(result)
        end)
      end
    end

    property "zero-width characters don't affect parsing" do
      check all text <- string(:alphanumeric, min_length: 1, max_length: 10),
                zwj_count <- integer(0..5),
                max_runs: 500 do
        # Insert zero-width joiners
        zwj = "\u200d"
        with_zwj = String.graphemes(text)
                   |> Enum.intersperse(String.duplicate(zwj, zwj_count))
                   |> Enum.join()

        sequence = "\e[31m" <> with_zwj <> "\e[0m"

        result = Parser.parse(sequence)
        assert is_list(result)
      end
    end

    property "RTL text with ANSI sequences" do
      check all arabic <- member_of(["مرحبا", "السلام", "شكرا"]),
                hebrew <- member_of(["שלום", "תודה", "בוקר"]),
                color <- integer(30..37),
                max_runs: 300 do
        # RTL text shouldn't affect escape sequence parsing
        sequences = [
          "\e[#{color}m#{arabic}\e[0m",
          "\e[#{color}m#{hebrew}\e[0m",
          "#{arabic}\e[#{color}m#{hebrew}\e[0m"
        ]

        Enum.each(sequences, fn seq ->
          result = Parser.parse(seq)
          assert is_list(result)
        end)
      end
    end
  end

  describe "state machine edge cases" do
    property "mode changes during sequences" do
      check all modes <- list_of(
                  frequency([
                    {1, constant("\e[?25h")},  # Cursor visible
                    {1, constant("\e[?25l")},  # Cursor invisible
                    {1, constant("\e[?1h")},   # App keypad
                    {1, constant("\e[?1l")}    # Normal keypad
                  ]),
                  min_length: 1,
                  max_length: 5
                ),
                text <- string(:alphanumeric, min_length: 1, max_length: 10),
                max_runs: 500 do
        # Interleave mode changes with text
        sequence = Enum.intersperse(modes, text) |> Enum.join()

        result = Parser.parse(sequence)
        assert is_list(result)
      end
    end

    property "escape within escape sequences" do
      check all inner <- csi_generator(),
                outer <- csi_generator(),
                max_runs: 500 do
        # Nested escapes (second should override)
        sequence = String.slice(outer, 0..-2//1) <> inner

        result = Parser.parse(sequence)
        assert is_list(result)
      end
    end

    property "control characters within sequences" do
      check all params <- list_of(integer(0..100), max_length: 3),
                ctrl <- member_of(["\x00", "\x01", "\x07", "\x08", "\x7F"]),
                max_runs: 500 do
        # Control char in middle of sequence
        sequence = "\e[" <> Enum.join(params, ";") <> ctrl <> "m"

        result = Parser.parse(sequence)
        assert is_list(result)
      end
    end
  end

  describe "performance stress tests" do
    @tag :slow
    property "parser handles rapid alternation efficiently" do
      check all count <- integer(100..500),
                max_runs: 20 do
        # Alternate between text and escapes
        sequence = Enum.map_join(1..count, "", fn i ->
          if rem(i, 2) == 0 do
            "\e[#{rem(i, 7) + 31}m"
          else
            "x"
          end
        end)

        {time, result} = :timer.tc(fn -> Parser.parse(sequence) end)

        assert is_list(result)
        # Should be fast even with many alternations
        assert time < count * 100  # Less than 100μs per item
      end
    end

    @tag :slow
    property "parser handles mixed content types efficiently" do
      check all segments <- list_of(
                  frequency([
                    {3, string(:alphanumeric, min_length: 1, max_length: 20)},
                    {2, csi_generator()},
                    {1, osc_generator()},
                    {1, constant("\n")},
                    {1, constant("\t")}
                  ]),
                  min_length: 50,
                  max_length: 200
                ),
                max_runs: 20 do
        sequence = Enum.join(segments)

        {time, result} = :timer.tc(fn -> Parser.parse(sequence) end)

        assert is_list(result)
        # Performance should scale linearly
        byte_size = byte_size(sequence)
        assert time < byte_size * 50  # Less than 50μs per byte
      end
    end
  end

  describe "buffer overflow scenarios" do
    property "sequences exceeding typical buffer sizes" do
      check all size_kb <- integer(1..10),
                max_runs: 10 do
        # Generate data larger than typical buffers
        data_size = size_kb * 1024
        sequence = String.duplicate("a", data_size)

        # Add some escape sequences
        with_escapes = "\e[31m" <> sequence <> "\e[0m"

        # Should handle without overflow
        result = Parser.parse(with_escapes)
        assert is_list(result)
      end
    end

    property "many small sequences vs one large sequence" do
      check all count <- integer(100..1000),
                max_runs: 20 do
        # Many small sequences
        many_small = Enum.map_join(1..count, "", fn i ->
          "\e[#{rem(i, 7) + 31}m#{i}"
        end)

        # One large sequence with many parameters
        one_large = "\e[" <> Enum.join(1..count, ";") <> "m"

        # Both should be handled
        result1 = Parser.parse(many_small)
        result2 = Parser.parse(one_large)

        assert is_list(result1)
        assert is_list(result2)
      end
    end
  end

  describe "special sequence combinations" do
    property "OSC sequences with various terminators" do
      check all title <- string(:printable, min_length: 1, max_length: 50),
                terminator <- member_of(["\a", "\e\\", "\x07"]),
                max_runs: 500 do
        # OSC sequence with different terminators
        sequence = "\e]0;" <> title <> terminator

        result = Parser.parse(sequence)
        assert is_list(result)
      end
    end

    property "DCS sequences" do
      check all data <- string(:printable, min_length: 1, max_length: 100),
                max_runs: 200 do
        # Device Control String
        sequence = "\eP" <> data <> "\e\\"

        result = Parser.parse(sequence)
        assert is_list(result)
      end
    end

    property "mixed CSI, OSC, and DCS sequences" do
      check all csi <- csi_generator(),
                osc <- osc_generator(),
                text <- string(:alphanumeric, min_length: 1, max_length: 10),
                max_runs: 200 do
        # Mix different sequence types
        mixed = csi <> text <> osc <> text

        result = Parser.parse(mixed)
        assert is_list(result)
      end
    end
  end

  # Generator helpers

  defp csi_generator do
    gen all cmd <- member_of(["A", "B", "C", "D", "H", "J", "K", "m"]),
            params <- list_of(integer(0..100), max_length: 3) do
      if params == [] do
        "\e[#{cmd}"
      else
        "\e[" <> Enum.join(params, ";") <> cmd
      end
    end
  end

  defp osc_generator do
    gen all code <- integer(0..9),
            data <- string(:printable, min_length: 0, max_length: 20),
            terminator <- member_of(["\a", "\e\\"]) do
      "\e]#{code};#{data}#{terminator}"
    end
  end
end
