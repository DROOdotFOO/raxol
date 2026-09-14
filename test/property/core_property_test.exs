defmodule Raxol.Property.CoreTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Terminal.ANSI.Utils.AnsiParser, as: Parser
  alias Raxol.Terminal.Buffer

  describe "Parser property tests" do
    property "parser handles all valid CSI sequences" do
      check all(
              sequence <- csi_sequence_generator(),
              max_runs: 500
            ) do
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
      check all(
              input <- string(:printable, min_length: 1, max_length: 100),
              max_runs: 1000
            ) do
        # Parser should handle any input without crashing
        result = Parser.parse(input)
        assert is_list(result)
      end
    end

    property "parser preserves text content" do
      check all(
              text <- string(:alphanumeric, min_length: 1, max_length: 50),
              max_runs: 500
            ) do
        # Pure text should be preserved
        parsed = Parser.parse(text)

        # Extract text from parsed result
        extracted = extract_text(parsed)
        assert String.contains?(extracted, text) or extracted == text
      end
    end

    property "escape sequences are idempotent" do
      check all(
              sequence <- simple_escape_sequence(),
              max_runs: 500
            ) do
        # Parsing twice should give same result
        parsed1 = Parser.parse(sequence)
        parsed2 = Parser.parse(sequence)

        assert parsed1 == parsed2
      end
    end

    # Was a wall-clock RATIO: parse 100 chars, parse `size` chars, assert the
    # second took less than 20x linear. At sizes of 100..1000 both samples are
    # microseconds, so the ratio measured the scheduler more than the parser
    # -- which is why it ended up `@tag :skip_on_ci`, i.e. guarding nothing
    # anywhere. A quadratic parser is also perfectly fast at 1000 chars, so
    # the old bound could not have caught one even when it ran.
    #
    # Size is the discriminator instead. At the parser's measured ~3.3us/char
    # a linear parse of 200k chars is well under a second; a quadratic one is
    # 4e10 character-steps, i.e. hours. The budget is the test's own timeout,
    # nothing is measured, and it runs on CI.
    @tag timeout: 30_000
    test "parsing 200k characters stays linear enough to finish" do
      input = String.duplicate("a", 200_000)

      assert is_list(Parser.parse(input))
    end
  end

  describe "Buffer property tests" do
    property "buffer maintains dimensions" do
      check all(
              width <- integer(10..200),
              height <- integer(10..100),
              max_runs: 200
            ) do
        buffer = Buffer.new({width, height})

        assert buffer.width == width
        assert buffer.height == height
        assert is_list(buffer.cells)
      end
    end

    property "buffer write operations preserve content" do
      check all(
              text <- string(:printable, min_length: 1, max_length: 50),
              max_runs: 500
            ) do
        buffer = Buffer.new({80, 24})
        updated = Buffer.write(buffer, text)

        # Buffer should still be valid
        assert updated.width == 80
        assert updated.height == 24
      end
    end
  end

  describe "Terminal state property tests" do
    property "terminal dimensions are valid" do
      check all(
              width <- integer(20..500),
              height <- integer(10..200),
              max_runs: 200
            ) do
        terminal = %{width: width, height: height}

        assert terminal.width > 0
        assert terminal.height > 0
        assert terminal.width <= 500
        assert terminal.height <= 200
      end
    end

    property "color values are in valid range" do
      check all(
              r <- integer(0..255),
              g <- integer(0..255),
              b <- integer(0..255),
              max_runs: 500
            ) do
        color = %{r: r, g: g, b: b}

        assert color.r in 0..255
        assert color.g in 0..255
        assert color.b in 0..255
      end
    end

    property "terminal modes are consistent" do
      check all(
              modes <- list_of(terminal_mode(), max_length: 20),
              max_runs: 200
            ) do
        terminal_state =
          Enum.reduce(modes, %{modes: MapSet.new()}, fn mode, state ->
            if :rand.uniform() > 0.5 do
              %{state | modes: MapSet.put(state.modes, mode)}
            else
              %{state | modes: MapSet.delete(state.modes, mode)}
            end
          end)

        # Modes should be a valid set
        assert is_struct(terminal_state.modes, MapSet)
        assert Enum.all?(terminal_state.modes, &is_atom/1)
      end
    end
  end

  # Generator helpers

  defp csi_sequence_generator do
    gen all(
          cmd <-
            member_of(["A", "B", "C", "D", "H", "J", "K", "m", "n", "s", "u"]),
          params <- list_of(integer(0..100), max_length: 3)
        ) do
      if params == [] do
        "\e[#{cmd}"
      else
        "\e[" <> Enum.join(params, ";") <> cmd
      end
    end
  end

  defp simple_escape_sequence do
    gen all(
          type <- member_of([:cursor_up, :cursor_down, :clear_screen, :reset])
        ) do
      case type do
        :cursor_up -> "\e[A"
        :cursor_down -> "\e[B"
        :clear_screen -> "\e[2J"
        :reset -> "\e[0m"
      end
    end
  end

  defp terminal_mode do
    member_of([:echo, :raw, :canonical, :insert, :autowrap, :cursor_visible])
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
