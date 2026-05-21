defmodule Raxol.Telegram.OutputAdapterPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Telegram.OutputAdapter

  describe "escape_html/1" do
    property "output never contains a raw < or >" do
      check all input <- string(:utf8) do
        output = OutputAdapter.escape_html(input)
        refute output =~ ~r/<(?!\/?(amp|lt|gt);)/
        refute output =~ ~r/>(?!\/?(amp|lt|gt);)/
      end
    end

    property "raw < and > are always replaced" do
      check all left <- string(:alphanumeric, max_length: 5),
                right <- string(:alphanumeric, max_length: 5),
                ch <- member_of(["<", ">"]) do
        input = left <> ch <> right
        output = OutputAdapter.escape_html(input)
        refute String.contains?(output, ch)
      end
    end

    property "& only appears as part of an entity reference in the output" do
      check all left <- string(:alphanumeric, max_length: 5),
                right <- string(:alphanumeric, max_length: 5) do
        input = left <> "&" <> right
        output = OutputAdapter.escape_html(input)
        # Every & in the output must be followed by amp; / lt; / gt;
        # (those are the only entities escape_html introduces).
        for part <- String.split(output, "&", trim: false) |> Enum.drop(1) do
          assert String.starts_with?(part, "amp;") or
                 String.starts_with?(part, "lt;") or
                 String.starts_with?(part, "gt;"),
                 "stray & in output: #{inspect(output)}"
        end
      end
    end

    property "double-escape is non-destructive on the original characters" do
      # escape_html is NOT idempotent because & in &lt; becomes &amp;lt;
      # but applying it once and twice should both produce strings that
      # don't contain raw < or >.
      check all input <- string(:utf8) do
        once = OutputAdapter.escape_html(input)
        twice = OutputAdapter.escape_html(once)
        refute twice =~ ~r/<(?!\/?(amp|lt|gt);)/
        refute twice =~ ~r/>(?!\/?(amp|lt|gt);)/
      end
    end

    property "ASCII-printable text without &, <, > passes through verbatim" do
      check all input <- string(:alphanumeric) do
        assert OutputAdapter.escape_html(input) == input
      end
    end
  end

  describe "buffer_to_text/1" do
    defp cell(char), do: %{char: char}

    defp buffer(rows) do
      %{cells: rows |> Enum.map(fn row -> Enum.map(row, &cell/1) end)}
    end

    property "every cell char appears in the output" do
      check all rows <-
                  list_of(
                    list_of(string(:alphanumeric, length: 1), min_length: 1, max_length: 8),
                    min_length: 1,
                    max_length: 5
                  ) do
        buf = buffer(rows)
        text = OutputAdapter.buffer_to_text(buf)
        all_chars = rows |> List.flatten() |> Enum.join("")
        # trailing-empty-line stripping may remove blank rows; spaces are
        # also trimmed off the right, so only non-space chars are guaranteed.
        for char <- String.graphemes(all_chars), char != " " do
          assert String.contains?(text, char)
        end
      end
    end

    property "output is bounded by total cell count + newlines" do
      check all rows <-
                  list_of(
                    list_of(string(:alphanumeric, length: 1), min_length: 1, max_length: 8),
                    min_length: 1,
                    max_length: 5
                  ) do
        buf = buffer(rows)
        text = OutputAdapter.buffer_to_text(buf)
        cell_total = rows |> List.flatten() |> length()
        newline_max = length(rows) - 1
        # Each grapheme uses at least 1 byte; we never expand chars.
        assert String.length(text) <= cell_total + newline_max
      end
    end
  end

  describe "build_keyboard/1" do
    property "build_keyboard always returns at least one row" do
      check all tree <-
                  one_of([
                    constant(nil),
                    constant(%{}),
                    constant(%{type: :other}),
                    constant([])
                  ]) do
        assert [_ | _] = OutputAdapter.build_keyboard(tree)
      end
    end

    property "buttons extracted from the view tree appear in the keyboard" do
      button_pair =
        tuple({
          string(:alphanumeric, min_length: 1, max_length: 8),
          string(:alphanumeric, min_length: 1, max_length: 8)
        })

      check all pairs <- list_of(button_pair, min_length: 1, max_length: 4) do
        button_nodes =
          Enum.map(pairs, fn {id, label} ->
            %{type: :button, id: id, content: label}
          end)

        tree = %{type: :container, children: button_nodes}
        keyboard = OutputAdapter.build_keyboard(tree)

        # Buttons appear as a row prepended to the default keyboard.
        [button_row | _default] = keyboard

        for {id, label} <- pairs do
          assert Enum.any?(button_row, fn btn ->
                   btn.text == label and btn.callback_data == "btn:" <> id
                 end)
        end
      end
    end
  end
end
