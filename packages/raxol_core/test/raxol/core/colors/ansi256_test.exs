defmodule Raxol.Core.Colors.Ansi256Test do
  @moduledoc """
  Pins the xterm 256-color cube against the real xterm ramp.

  Three call sites -- `Raxol.Style.Colors.Formats.ansi_to_rgb/1`,
  `Raxol.LiveView.TerminalBridge`'s `color_256_to_rgb/1`, and
  `Raxol.Terminal.ANSI.SixelPalette` -- each computed the cube as `n * 51`,
  which agrees with xterm only at the two endpoints. Nothing in the suite
  asserted a cube value, so all 208 wrong colors were invisible, and the two
  same-named converters (`Theming.Colors.ansi_to_rgb/1`, accurate, and
  `Style.Colors.Formats.ansi_to_rgb/1`, naive) silently disagreed.
  """
  use ExUnit.Case, async: true

  doctest Raxol.Core.Colors.Ansi256

  alias Raxol.Core.Colors.Ansi256

  describe "cube_level/1" do
    test "matches the xterm channel ramp exactly" do
      assert Enum.map(0..5, &Ansi256.cube_level/1) ==
               [0, 95, 135, 175, 215, 255]
    end

    test "is not the naive linear ramp" do
      # The regression being guarded: `n * 51` gives this instead.
      refute Enum.map(0..5, &Ansi256.cube_level/1) ==
               [0, 51, 102, 153, 204, 255]
    end
  end

  describe "cube_rgb/1" do
    test "index 16 is black and 231 is white" do
      assert Ansi256.cube_rgb(16) == {0, 0, 0}
      assert Ansi256.cube_rgb(231) == {255, 255, 255}
    end

    test "index 17 is the first blue step, the canonical wrong value" do
      # `n * 51` yields {0, 0, 51} here.
      assert Ansi256.cube_rgb(17) == {0, 0, 95}
    end

    test "decomposes the index into r, g, b axes in xterm order" do
      # 16 + 36*r + 6*g + b
      assert Ansi256.cube_rgb(16 + 36 * 5) == {255, 0, 0}
      assert Ansi256.cube_rgb(16 + 6 * 5) == {0, 255, 0}
      assert Ansi256.cube_rgb(16 + 5) == {0, 0, 255}
      assert Ansi256.cube_rgb(16 + 36 * 1 + 6 * 2 + 3) == {95, 135, 175}
    end

    test "every channel of every cube color is a legal xterm level" do
      levels = [0, 95, 135, 175, 215, 255]

      for index <- 16..231, channel <- Tuple.to_list(Ansi256.cube_rgb(index)) do
        assert channel in levels,
               "index #{index} produced channel #{channel}, not an xterm level"
      end
    end

    test "the cube is injective across all 216 indices" do
      cube = Enum.map(16..231, &Ansi256.cube_rgb/1)
      assert length(Enum.uniq(cube)) == 216
    end
  end

  describe "grayscale_rgb/1" do
    test "spans 8..238 in steps of 10" do
      assert Ansi256.grayscale_rgb(232) == {8, 8, 8}
      assert Ansi256.grayscale_rgb(255) == {238, 238, 238}
    end

    test "is always neutral" do
      for index <- 232..255 do
        assert {v, v, v} = Ansi256.grayscale_rgb(index)
        assert v == (index - 232) * 10 + 8
      end
    end
  end

  describe "to_rgb/1" do
    test "dispatches cube and ramp on the 231/232 boundary" do
      assert Ansi256.to_rgb(231) == Ansi256.cube_rgb(231)
      assert Ansi256.to_rgb(232) == Ansi256.grayscale_rgb(232)
    end

    test "refuses indices below 16, which are a theme convention" do
      assert_raise FunctionClauseError, fn -> Ansi256.to_rgb(15) end
    end
  end
end
