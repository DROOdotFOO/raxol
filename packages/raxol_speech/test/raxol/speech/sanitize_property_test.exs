defmodule Raxol.Speech.TTS.SanitizePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Speech.TTS.Sanitize

  @control_chars [0x00..0x08, 0x0B..0x0C, 0x0E..0x1F, [0x7F]]
                 |> Enum.flat_map(&Enum.to_list/1)

  describe "strip_control_chars/1" do
    property "output contains no control characters for any input" do
      check all input <- string(:utf8) do
        output = Sanitize.strip_control_chars(input)

        for cp <- @control_chars do
          refute String.contains?(output, <<cp::utf8>>),
                 "control char #{inspect(cp)} survived sanitization"
        end
      end
    end

    property "output is never longer than input (in bytes)" do
      check all input <- string(:utf8) do
        assert byte_size(Sanitize.strip_control_chars(input)) <= byte_size(input)
      end
    end

    property "ASCII printable text passes through verbatim" do
      check all input <- string(:printable) do
        # :printable includes \t, \n, \r, and printable ASCII; only \r is not
        # in the strip set, so filter input to characters the sanitizer keeps.
        kept = String.replace(input, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
        assert Sanitize.strip_control_chars(input) == kept
      end
    end

    property "tabs and newlines are preserved" do
      check all prefix <- string(:alphanumeric, max_length: 10),
                suffix <- string(:alphanumeric, max_length: 10) do
        input = prefix <> "\t\n" <> suffix
        output = Sanitize.strip_control_chars(input)
        assert String.contains?(output, "\t")
        assert String.contains?(output, "\n")
      end
    end

    property "idempotent: strip(strip(x)) == strip(x)" do
      check all input <- string(:utf8) do
        once = Sanitize.strip_control_chars(input)
        twice = Sanitize.strip_control_chars(once)
        assert once == twice
      end
    end

    property "control chars at any position are removed" do
      check all left <- string(:alphanumeric, max_length: 5),
                right <- string(:alphanumeric, max_length: 5),
                cp <- member_of(@control_chars) do
        input = left <> <<cp::utf8>> <> right
        output = Sanitize.strip_control_chars(input)
        refute String.contains?(output, <<cp::utf8>>)
      end
    end
  end
end
