defmodule Raxol.Utils.ColorConversionTest do
  @moduledoc """
  The lenient hex parser, and its agreement with the strict ones.

  Three `hex_to_rgb/1` implementations existed with a hand-rolled parser in
  this one. On identical input they disagreed:

      input        this module    Theming.Colors   Renderer.Color
      "#FFF"       {0,0,0}        {255,255,255}    {255,255,255}
      "#FF000080"  {0,0,0}        {255,0,0}        ArgumentError
      "#zzzzzz"    MatchError     BadMapError      ArgumentError

  The first two rows were silent wrong-colour bugs on a live path: this
  function is what `Raxol.UI.Terminal`, `Raxol.Protocols.ThemeImplementations`
  and `Raxol.Protocols.RendererImplementations` call, so a theme using
  3-digit shorthand hex rendered black. The third contradicted this
  function's own `@spec` and doctest.

  All three now delegate to `Raxol.Style.Colors.Formats.from_hex/1`.
  """
  use ExUnit.Case, async: true

  doctest Raxol.Utils.ColorConversion

  alias Raxol.Core.Renderer.Color, as: RendererColor
  alias Raxol.UI.Theming.Colors, as: ThemeColors
  alias Raxol.Utils.ColorConversion

  describe "hex_to_rgb/1 accepts every hex form the codebase ships" do
    test "6-digit" do
      assert ColorConversion.hex_to_rgb("#FF0000") == {255, 0, 0}
      assert ColorConversion.hex_to_rgb("#00FF00") == {0, 255, 0}
    end

    test "3-digit shorthand expands rather than failing to black" do
      assert ColorConversion.hex_to_rgb("#FFF") == {255, 255, 255}
      assert ColorConversion.hex_to_rgb("#F00") == {255, 0, 0}
      assert ColorConversion.hex_to_rgb("#0F0") == {0, 255, 0}
    end

    test "8-digit alpha hex drops the alpha channel" do
      assert ColorConversion.hex_to_rgb("#FF000080") == {255, 0, 0}
    end

    test "lowercase" do
      assert ColorConversion.hex_to_rgb("#ff0000") == {255, 0, 0}
      assert ColorConversion.hex_to_rgb("#f00") == {255, 0, 0}
    end
  end

  describe "hex_to_rgb/1 is lenient, never raising" do
    test "unparseable input yields black, per its spec" do
      # Previously a MatchError from `{r, ""} = Integer.parse("zz", 16)`.
      assert ColorConversion.hex_to_rgb("#zzzzzz") == {0, 0, 0}
      assert ColorConversion.hex_to_rgb("invalid") == {0, 0, 0}
      assert ColorConversion.hex_to_rgb("") == {0, 0, 0}
      assert ColorConversion.hex_to_rgb("#") == {0, 0, 0}
    end

    test "a non-binary yields black" do
      assert ColorConversion.hex_to_rgb(nil) == {0, 0, 0}
      assert ColorConversion.hex_to_rgb(:red) == {0, 0, 0}
    end
  end

  describe "agreement with the strict implementations" do
    test "all three agree on every valid RGB hex form" do
      for hex <- ["#FF0000", "#00FF00", "#0000FF", "#F00", "#0F0", "#ffffff"] do
        expected = RendererColor.hex_to_rgb(hex)

        assert ColorConversion.hex_to_rgb(hex) == expected,
               "lenient parser disagrees on #{hex}"

        assert ThemeColors.hex_to_rgb(hex) == expected,
               "Theming.Colors disagrees on #{hex}"
      end
    end

    test "the strict pair raises a named error, not an incidental one" do
      # Was BadMapError, from reading .r off an {:error, :invalid_hex} tuple.
      assert_raise ArgumentError, fn -> ThemeColors.hex_to_rgb("nothex") end
      assert_raise ArgumentError, fn -> RendererColor.hex_to_rgb("nothex") end
    end

    test "only the alpha-hex strictness still differs, deliberately" do
      # Renderer.Color rejects 4/8-digit hex; the other two drop the alpha.
      # Pinned so the divergence stays a decision rather than drifting back
      # into three accidental behaviours.
      assert ColorConversion.hex_to_rgb("#FF000080") == {255, 0, 0}
      assert ThemeColors.hex_to_rgb("#FF000080") == {255, 0, 0}
      assert_raise ArgumentError, fn -> RendererColor.hex_to_rgb("#FF000080") end
    end
  end
end
