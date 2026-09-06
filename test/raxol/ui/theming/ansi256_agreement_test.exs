defmodule Raxol.UI.Theming.Ansi256AgreementTest do
  @moduledoc """
  The forward and reverse 256-color lookups must describe the same palette.

  `Raxol.UI.Theming.Colors.ansi_to_rgb/1` (index -> RGB) resolves through
  `Raxol.Style.Colors.Color.from_ansi/1` -> `Formats.ansi_to_rgb/1`, which
  computed the 6x6x6 cube as `n * 51`. `find_closest_256_color/1` (RGB ->
  index) searches `@ansi_216_colors`, built from the real xterm ramp
  `55 + n * 40`. The two therefore described different palettes: every cube
  index but the 8 that coincide with a basic color failed to round-trip, and
  no test noticed.

  Both sides now share `Raxol.Core.Colors.Ansi256`.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Theming.Colors

  # Cube indices whose RGB is byte-identical to one of the basic 16 colors.
  # `find_closest_256_color/1` searches basic colors first and legitimately
  # returns the lower index for these, so they cannot round-trip and are not
  # expected to.
  @basic_aliases [196, 201, 226, 231, 46, 51, 21, 16]

  describe "cube round-trip" do
    test "every cube index round-trips, except exact basic-color aliases" do
      mismatches =
        for index <- 16..231,
            index not in @basic_aliases,
            rgb = Colors.ansi_to_rgb(index),
            Colors.find_closest_256_color(rgb) != index,
            do: {index, rgb, Colors.find_closest_256_color(rgb)}

      assert mismatches == [],
             "forward and reverse lookups disagree for: #{inspect(mismatches)}"
    end

    test "the basic-color aliases resolve to their basic index, not the cube" do
      # Not incidental: these are the only indices where the cube duplicates a
      # basic color, and preferring the lower index is the intended behaviour.
      assert Colors.find_closest_256_color(Colors.ansi_to_rgb(231)) == 15
      assert Colors.find_closest_256_color(Colors.ansi_to_rgb(16)) == 0
    end
  end

  describe "forward lookup" do
    test "agrees with the shared table across the whole cube and ramp" do
      for index <- 16..255 do
        assert Colors.ansi_to_rgb(index) ==
                 Raxol.Core.Colors.Ansi256.to_rgb(index),
               "index #{index} disagrees with Raxol.Core.Colors.Ansi256"
      end
    end

    test "uses the xterm ramp, not the naive linear one" do
      assert Colors.ansi_to_rgb(17) == {0, 0, 95}
      refute Colors.ansi_to_rgb(17) == {0, 0, 51}
    end
  end
end
