defmodule Raxol.Terminal.ANSI.Sequences.ColorsTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ANSI.Sequences.Colors

  describe "parse_color/1 hex" do
    test "parses a valid 6-digit hex to an rgb map" do
      assert Colors.parse_color("#ff8800") == %{r: 255, g: 136, b: 0}
    end

    test "returns nil for a 3-digit hex (6-digit only at this site)" do
      assert Colors.parse_color("#f80") == nil
    end

    test "returns nil for invalid hex digits" do
      assert Colors.parse_color("#gg0000") == nil
    end

    test "returns nil for an over-length hex string" do
      assert Colors.parse_color("#1234567") == nil
    end
  end
end
