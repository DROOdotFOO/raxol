defmodule Raxol.UI.CellDimTest do
  @moduledoc """
  Coverage for `Raxol.UI.CellDim`'s H-K-compensated, apparent-lightness
  contrast compression toward ground. No test here stores a background
  via `Raxol.Terminal.Driver.BackgroundQuery` -- that's global
  `:persistent_term` state shared with concurrently running async test
  modules, so ground overrides go through `dim_color/2` instead (mirrors
  `Raxol.UI.Theming.SalienceThemeTest`'s `ground:` override pattern).
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.CellDim
  alias Raxol.UI.Theming.Salience

  # No detection stored anywhere in this test run -> CellDim falls back to
  # Salience's reference ground (achromatic, so its apparent lightness
  # equals its nominal lightness exactly).
  @dark_ground_al Salience.apparent_lightness(
                    Salience.reference_ground(),
                    0.0,
                    0.0
                  )
  @light_ground_al Salience.apparent_lightness(0.95, 0.0, 0.0)

  defp apparent_lightness_of_rgb({r, g, b}) do
    {l, c, h} = Salience.rgb_to_oklch(r / 255, g / 255, b / 255)
    Salience.apparent_lightness(l, c, h)
  end

  describe "dark ground (default, no detection)" do
    test "pins the default-ground dim values" do
      assert CellDim.dim_color(:white) == {106, 106, 106}
      assert CellDim.dim_color(:cyan) == {3, 100, 100}
      # unlisted atom resolves to mid-gray before dimming, not a crash
      assert CellDim.dim_color(:some_theme_color) == {66, 66, 66}
      assert CellDim.dim_color({200, 100, 50}) == {108, 49, 20}
      assert CellDim.dim_color({0, 0, 0}) == {4, 4, 4}
      assert CellDim.dim_color({255, 255, 255}) == {116, 116, 116}
      assert CellDim.dim_color(nil) == nil
      assert CellDim.dim_color(42) == 42
      assert CellDim.dim_color("#ff0000") == "#8a0000"

      # :black is unpainted-bg sentinel -- pass through like nil, see @moduledoc.
      assert CellDim.dim_color(:black) == :black
    end

    test "a bright color's dimmed apparent lightness drops and moves closer to ground" do
      original_al = apparent_lightness_of_rgb({255, 255, 255})
      dimmed = CellDim.dim_color({255, 255, 255}, @dark_ground_al)
      dimmed_al = apparent_lightness_of_rgb(dimmed)

      assert dimmed_al < original_al

      assert abs(dimmed_al - @dark_ground_al) <
               abs(original_al - @dark_ground_al)
    end
  end

  describe "light ground" do
    test "a near-black color's dimmed apparent lightness rises and moves closer to ground (washes toward white)" do
      original_al = apparent_lightness_of_rgb({10, 10, 10})
      dimmed = CellDim.dim_color({10, 10, 10}, @light_ground_al)
      dimmed_al = apparent_lightness_of_rgb(dimmed)

      assert dimmed_al > original_al

      assert abs(dimmed_al - @light_ground_al) <
               abs(original_al - @light_ground_al)
    end

    test "direction flips relative to the same color on a dark ground" do
      dark_dimmed = CellDim.dim_color({10, 10, 10}, @dark_ground_al)
      light_dimmed = CellDim.dim_color({10, 10, 10}, @light_ground_al)

      assert apparent_lightness_of_rgb(dark_dimmed) <
               apparent_lightness_of_rgb(light_dimmed)
    end
  end

  test "nil always passes through" do
    assert CellDim.dim_color(nil) == nil
    assert CellDim.dim_color(nil, @dark_ground_al) == nil
    assert CellDim.dim_color(nil, @light_ground_al) == nil
  end

  test "hue is preserved within a few degrees through the OKLCH round trip" do
    {_l, _c, h} = Salience.rgb_to_oklch(200 / 255, 100 / 255, 50 / 255)
    dimmed = CellDim.dim_color({200, 100, 50}, @dark_ground_al)

    {_dl, _dc, dh} =
      Salience.rgb_to_oklch(
        elem(dimmed, 0) / 255,
        elem(dimmed, 1) / 255,
        elem(dimmed, 2) / 255
      )

    assert_in_delta h, dh, 3.0
  end

  test "chroma is reduced" do
    {_l, c, _h} = Salience.rgb_to_oklch(200 / 255, 100 / 255, 50 / 255)
    dimmed = CellDim.dim_color({200, 100, 50}, @dark_ground_al)

    {_dl, dc, _dh} =
      Salience.rgb_to_oklch(
        elem(dimmed, 0) / 255,
        elem(dimmed, 1) / 255,
        elem(dimmed, 2) / 255
      )

    assert dc < c
  end

  describe "dim_fg/2 and dim_bg/2 (:black role split)" do
    test "dim_fg treats a painted :black as a real color and dims it" do
      assert CellDim.dim_fg(:black, @dark_ground_al) ==
               CellDim.dim_color({0, 0, 0}, @dark_ground_al)

      assert CellDim.dim_fg(:black, @dark_ground_al) != :black
    end

    test "dim_bg keeps :black as the unpainted-bg sentinel" do
      assert CellDim.dim_bg(:black, @dark_ground_al) == :black
    end

    test "both delegate to dim_color/2 for non-:black colors" do
      assert CellDim.dim_fg(:cyan, @dark_ground_al) ==
               CellDim.dim_color(:cyan, @dark_ground_al)

      assert CellDim.dim_bg({200, 100, 50}, @dark_ground_al) ==
               CellDim.dim_color({200, 100, 50}, @dark_ground_al)
    end
  end

  test "dimming twice does not crash (idempotence not required)" do
    once = CellDim.dim_color({200, 100, 50})
    assert is_tuple(CellDim.dim_color(once))
    assert CellDim.dim_color(CellDim.dim_color(:white)) |> is_tuple()
  end

  describe "dim_cells/1" do
    test "dedupes and dims every cell's fg/bg, leaving char/coords/attrs untouched" do
      cells = [
        {0, 0, "a", :white, {200, 100, 50}, [:bold]},
        {1, 0, "b", :white, {200, 100, 50}, []},
        {2, 0, "c", nil, nil, []}
      ]

      dimmed = CellDim.dim_cells(cells)

      assert [
               {0, 0, "a", {106, 106, 106}, {108, 49, 20}, [:bold]},
               {1, 0, "b", {106, 106, 106}, {108, 49, 20}, []},
               {2, 0, "c", nil, nil, []}
             ] = dimmed
    end

    test "empty list does not crash" do
      assert CellDim.dim_cells([]) == []
    end

    test "bg :black sentinel passes through unchanged alongside a dimmed fg" do
      cells = [{0, 0, "a", :cyan, :black, []}]

      assert [{0, 0, "a", {3, 100, 100}, :black, []}] =
               CellDim.dim_cells(cells)
    end

    test "fg :black dims while bg :black stays the sentinel, in the same cell" do
      cells = [{0, 0, "a", :black, :black, []}]

      assert [{0, 0, "a", {4, 4, 4}, :black, []}] = CellDim.dim_cells(cells)
    end
  end

  describe "chroma/contrast split" do
    test "dimmed chroma stays well above the just-noticeable threshold for saturated ANSI colors" do
      for color <- [:blue, :cyan, :green, :red, :magenta, :yellow] do
        {r, g, b} = CellDim.dim_color(color, @dark_ground_al)
        {_l, c, _h} = Salience.rgb_to_oklch(r / 255, g / 255, b / 255)

        assert c > 0.04,
               "#{color} dimmed to chroma #{c}, expected > 0.04 (hue should stay legible)"
      end
    end

    test "chroma keep factor is looser than the contrast keep factor" do
      {l, c, h} = Salience.rgb_to_oklch(0 / 255, 0 / 255, 238 / 255)
      apparent_l = Salience.apparent_lightness(l, c, h)

      dimmed = CellDim.dim_color({0, 0, 238}, @dark_ground_al)

      {dl, dc, dh} =
        Salience.rgb_to_oklch(
          elem(dimmed, 0) / 255,
          elem(dimmed, 1) / 255,
          elem(dimmed, 2) / 255
        )

      dimmed_apparent_l = Salience.apparent_lightness(dl, dc, dh)

      contrast_ratio =
        abs(dimmed_apparent_l - @dark_ground_al) /
          abs(apparent_l - @dark_ground_al)

      chroma_ratio = dc / c

      assert chroma_ratio > contrast_ratio
    end
  end
end
