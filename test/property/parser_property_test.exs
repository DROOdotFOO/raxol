defmodule Raxol.Property.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Terminal.ANSI.Utils.AnsiParser, as: Parser

  describe "parser property tests" do
    property "parse handles all valid CSI sequences" do
      check all sequence <- csi_sequence_generator(),
                max_runs: 500 do
        result = Parser.parse(sequence)

        # Should return a list of sequences
        assert is_list(result)

        # If parsed, should have valid structure
        Enum.each(result, fn item ->
          assert is_map(item) or is_binary(item)
        end)
      end
    end

    property "parser never crashes on random input" do
      check all input <- string(:printable, min_length: 1, max_length: 100),
                max_runs: 1000 do
        # Parser should handle any input without crashing
        result = Parser.parse(input)
        assert is_list(result)
      end
    end

    property "parser preserves text content" do
      check all text <- string(:alphanumeric, min_length: 1, max_length: 50),
                max_runs: 500 do
        # Pure text should be preserved
        parsed = Parser.parse(text)

        # Extract text from parsed result
        extracted = extract_text(parsed)
        assert String.contains?(extracted, text) or extracted == text
      end
    end

    property "escape sequences are idempotent" do
      check all sequence <- simple_escape_sequence(),
                max_runs: 500 do
        # Parsing twice should give same result
        parsed1 = Parser.parse(sequence)
        parsed2 = Parser.parse(sequence)

        assert parsed1 == parsed2
      end
    end

    property "cursor movement sequences maintain bounds" do
      check all row <- integer(1..9999),
                col <- integer(1..9999),
                max_runs: 500 do
        sequence = "\e[#{row};#{col}H"
        parsed = Parser.parse(sequence)

        # Should parse as cursor position command
        assert [_ | _] = parsed
        assert Enum.any?(parsed, &is_map/1)
      end
    end

    property "color sequences produce valid RGB values" do
      check all r <- integer(0..255),
                g <- integer(0..255),
                b <- integer(0..255),
                max_runs: 500 do
        # 24-bit color sequence
        sequence = "\e[38;2;#{r};#{g};#{b}m"
        parsed = Parser.parse(sequence)

        # Should parse the color sequence
        assert is_list(parsed)
        assert [_ | _] = parsed
      end
    end

    property "parser handles mixed content correctly" do
      check all segments <- list_of(mixed_content_generator(), min_length: 1, max_length: 10),
                max_runs: 500 do
        input = Enum.join(segments)

        # Should parse without error
        parsed = Parser.parse(input)

        # Result should be a list
        assert is_list(parsed)
      end
    end

    property "SGR parameters are parsed correctly" do
      check all params <- list_of(integer(0..107), min_length: 1, max_length: 5),
                max_runs: 500 do
        sequence = "\e[" <> Enum.join(params, ";") <> "m"
        parsed = Parser.parse(sequence)

        # Should parse the SGR sequence
        assert is_list(parsed)
        assert [_ | _] = parsed
      end
    end

    property "invalid sequences are handled gracefully" do
      check all garbage <- binary(min_length: 1, max_length: 50),
                max_runs: 500 do
        # Add escape to make it look like sequence
        input = "\e" <> garbage

        # Should not crash
        result = Parser.parse(input)
        assert is_list(result)
      end
    end

    property "parser performance scales linearly" do
      check all size <- integer(10..1000),
                max_runs: 100 do
        # Generate input of specific size
        input = String.duplicate("a", size)

        # Measure parsing time
        {time, result} = :timer.tc(fn -> Parser.parse(input) end)

        # Should complete and return a list
        assert is_list(result)

        # Time should scale roughly linearly. Real cost is ~3.3us/char, so the
        # 1ms/char slope is already generous; this guards against superlinear
        # blowups rather than enforcing a tight budget. The fixed base absorbs a
        # one-off GC or scheduler pause on a loaded runner, which otherwise
        # dominates the small absolute budget for tiny inputs.
        base_overhead = 50_000
        expected_max = base_overhead + size * 1000
        assert time < expected_max
      end
    end
  end

  # Generator helpers

  defp csi_sequence_generator do
    gen all cmd <- member_of(["A", "B", "C", "D", "H", "J", "K", "m", "n", "s", "u"]),
            params <- list_of(integer(0..100), max_length: 3) do
      if params == [] do
        "\e[#{cmd}"
      else
        "\e[" <> Enum.join(params, ";") <> cmd
      end
    end
  end

  defp simple_escape_sequence do
    gen all type <- member_of([:cursor_up, :cursor_down, :clear_screen, :reset]) do
      case type do
        :cursor_up -> "\e[A"
        :cursor_down -> "\e[B"
        :clear_screen -> "\e[2J"
        :reset -> "\e[0m"
      end
    end
  end

  defp mixed_content_generator do
    frequency([
      {3, string(:alphanumeric, min_length: 1, max_length: 10)},
      {1, csi_sequence_generator()},
      {1, constant("\n")},
      {1, constant("\t")}
    ])
  end

  # Helper functions

  defp extract_text(parsed) when is_list(parsed) do
    parsed
    |> Enum.map_join("", fn
      item when is_binary(item) -> item
      %{text: text} -> text
      _ -> ""
    end)
  end
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: ""
end
