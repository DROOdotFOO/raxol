defmodule Raxol.UI.Theming.SalienceThemeTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Capabilities
  alias Raxol.UI.Theming.Ansi16Salience
  alias Raxol.UI.Theming.Salience
  alias Raxol.UI.Theming.SalienceTheme

  # Theme.new converts color values to Color structs; normalize to hex.
  defp hex(%{hex: h}), do: String.downcase(h)
  defp hex(h) when is_binary(h), do: String.downcase(h)

  test "dark ground yields lighter-than-ground foreground" do
    theme = SalienceTheme.build(ground: 0.2)
    {l, _, _} = Salience.hex_to_oklch(theme.colors.foreground)
    assert l > 0.2
  end

  test "light ground yields darker-than-ground foreground" do
    theme = SalienceTheme.build(ground: 0.95)
    {l, _, _} = Salience.hex_to_oklch(theme.colors.foreground)
    assert l < 0.95
  end

  test "same seeds solve to different palettes on different grounds" do
    dark = SalienceTheme.build(ground: 0.2)
    light = SalienceTheme.build(ground: 0.95)
    assert hex(dark.colors.accent) != hex(light.colors.accent)
  end

  test "reference ground reproduces darcula-family values" do
    theme = SalienceTheme.build(ground: 0.2)
    assert hex(theme.colors.warning) == "#bb6b25"
    assert hex(theme.colors.error) == "#af3434"
    assert hex(theme.colors.emphasis) == "#f8bf66"
    assert hex(theme.colors.success) == "#728e60"
  end

  test "detection fallback uses reference ground" do
    # No OSC 11 reply in test env -> fallback 0.2.
    ground = SalienceTheme.detect_ground()
    assert is_float(ground)
    assert ground >= 0.0 and ground <= 1.0
  end

  test "theme carries salience identity and full component styles" do
    theme = SalienceTheme.build(ground: 0.2)
    assert theme.id == :salience

    assert hex(theme.component_styles.focus.border_fg) ==
             hex(theme.colors.accent)
  end

  describe "detect_ground/0 fallback ladder" do
    setup do
      Capabilities.reset_cache()
      on_exit(fn -> Capabilities.reset_cache() end)
      :ok
    end

    test "record background present -> H-K apparent lightness of that background" do
      Capabilities.cache(%Capabilities{background: {30, 30, 30}})

      expected_al = Salience.apparent_lightness_of_rgb(30, 30, 30)

      assert_in_delta SalienceTheme.detect_ground(), expected_al, 1.0e-9
    end

    # Regression (A6): the fixture above is already achromatic, so it
    # already proves AL == L for this ground (`Salience.apparent_lightness_of_rgb/3`
    # collapses to nominal L when chroma is 0 -- see
    # `salience_test.exs`'s "apparent_lightness_of_rgb/3 (A6)" describe
    # block for the general-case regression across a gray sweep, without
    # the global `Capabilities` cache this describe block needs).

    # A6 (V, 2026-07-19): a tinted (green) background reads brighter to a
    # human viewer than its bare OKLCH `L` suggests -- the ground the
    # solver ranks tiers against must be the H-K apparent lightness of the
    # detected color, not nominal `L`.
    test "tinted (green) background -> apparent lightness, not nominal L" do
      {r, g, b} = {0x1A, 0x8F, 0x1A}
      Capabilities.cache(%Capabilities{background: {r, g, b}})

      {nominal_l, c, _h} = Salience.rgb_to_oklch(r / 255, g / 255, b / 255)
      expected_al = Salience.apparent_lightness_of_rgb(r, g, b)

      # A saturated green background has substantial chroma, so this
      # fixture actually exercises the H-K term (not a degenerate
      # near-achromatic case where AL and L would coincide anyway).
      assert c > 0.1
      assert expected_al > nominal_l

      assert_in_delta SalienceTheme.detect_ground(), expected_al, 1.0e-9
      assert abs(SalienceTheme.detect_ground() - nominal_l) > 0.01
    end

    test "no background, polarity_seed :dark -> Salience.reference_ground/0" do
      Capabilities.cache(%Capabilities{background: nil, polarity_seed: :dark})

      assert SalienceTheme.detect_ground() == Salience.reference_ground()
    end

    test "no background, polarity_seed :light -> documented light reference" do
      Capabilities.cache(%Capabilities{background: nil, polarity_seed: :light})

      ground = SalienceTheme.detect_ground()
      assert ground == 0.95
      assert ground > 0.5
    end

    test "no record cached at all -> Salience.reference_ground/0" do
      assert Capabilities.cached() == :error
      assert SalienceTheme.detect_ground() == Salience.reference_ground()
    end

    test "record cached but neither background nor polarity_seed set -> reference_ground/0" do
      Capabilities.cache(%Capabilities{background: nil, polarity_seed: nil})

      assert SalienceTheme.detect_ground() == Salience.reference_ground()
    end
  end

  describe "detect_polarity/0" do
    setup do
      Capabilities.reset_cache()
      on_exit(fn -> Capabilities.reset_cache() end)
      :ok
    end

    test "delegates to Ansi16Salience.polarity/1 on the detected ground (no second threshold)" do
      Capabilities.cache(%Capabilities{background: {20, 20, 20}})

      assert SalienceTheme.detect_polarity() ==
               Ansi16Salience.polarity(SalienceTheme.detect_ground())
    end

    test "a clearly dark background resolves :dark" do
      Capabilities.cache(%Capabilities{background: {10, 10, 10}})
      assert SalienceTheme.detect_polarity() == :dark
    end

    test "a clearly light background resolves :light" do
      Capabilities.cache(%Capabilities{background: {245, 245, 245}})
      assert SalienceTheme.detect_polarity() == :light
    end
  end

  describe "detect_foreground_al/0" do
    setup do
      Capabilities.reset_cache()
      on_exit(fn -> Capabilities.reset_cache() end)
      :ok
    end

    test "returns nil when no record is cached" do
      assert SalienceTheme.detect_foreground_al() == nil
    end

    test "returns nil when a record is cached but carries no foreground" do
      Capabilities.cache(%Capabilities{foreground: nil})
      assert SalienceTheme.detect_foreground_al() == nil
    end

    test "returns H-K apparent lightness of the record's (achromatic) foreground when present" do
      Capabilities.cache(%Capabilities{foreground: {230, 230, 230}})

      expected_al = Salience.apparent_lightness_of_rgb(230, 230, 230)

      assert_in_delta SalienceTheme.detect_foreground_al(), expected_al, 1.0e-9
    end

    # A6: a tinted native foreground (rare, but not disallowed by OSC 10)
    # must also be read as apparent lightness, not nominal L.
    test "returns apparent lightness (not nominal L) of a tinted foreground" do
      {r, g, b} = {0x66, 0xCC, 0x66}
      Capabilities.cache(%Capabilities{foreground: {r, g, b}})

      {nominal_l, c, _h} = Salience.rgb_to_oklch(r / 255, g / 255, b / 255)
      expected_al = Salience.apparent_lightness_of_rgb(r, g, b)

      assert c > 0.01
      assert expected_al > nominal_l
      assert_in_delta SalienceTheme.detect_foreground_al(), expected_al, 1.0e-9
    end
  end

  describe "build/1 with :foreground_l (amendment A1 anchor bound)" do
    test "a known fg on the solving side lowers the anchor target below the absolute 0.97 bound" do
      ground = 0.2
      fg_al = 0.6

      loose_hex =
        Salience.solve(:anchor, 0.125, 77, ground: ground, polarity: :up)

      {loose_l, _c, _h} = Salience.hex_to_oklch(loose_hex)

      theme = SalienceTheme.build(ground: ground, foreground_l: fg_al)
      {bounded_l, _c, _h} = Salience.hex_to_oklch(theme.colors.emphasis)

      # emphasis is the :anchor-tier seed in the default table.
      assert bounded_l < loose_l

      tight_target =
        Salience.tier_target(:anchor, ground, :up, far_bound: fg_al)

      assert tight_target <= fg_al + 1.0e-9
    end

    # A6: the far_bound is meaningful specifically as an apparent-lightness
    # value -- a tinted fg's AL (derived via apparent_lightness_of_rgb/3,
    # the same helper detect_foreground_al/0 uses) must bound the solve
    # identically to a bare AL float, since :far_bound is documented as
    # already living in AL space.
    test "a tinted fg's apparent lightness works identically to a bare AL float as far_bound" do
      ground = 0.2
      {r, g, b} = {0x66, 0xCC, 0x66}
      fg_al = Salience.apparent_lightness_of_rgb(r, g, b)

      loose_hex =
        Salience.solve(:anchor, 0.125, 77, ground: ground, polarity: :up)

      {loose_l, _c, _h} = Salience.hex_to_oklch(loose_hex)

      theme = SalienceTheme.build(ground: ground, foreground_l: fg_al)
      {bounded_l, _c, _h} = Salience.hex_to_oklch(theme.colors.emphasis)

      assert bounded_l < loose_l

      tight_target =
        Salience.tier_target(:anchor, ground, :up, far_bound: fg_al)

      assert tight_target <= fg_al + 1.0e-9
    end

    test "nonsense-fg guard: a fg darker than a dark ground is ignored" do
      ground = 0.2
      # fg darker than the (dark) ground makes no sense as an upper bound;
      # build/1 must fall through to the absolute 0.97 bound unchanged.
      nonsense_fg_al = 0.05

      with_nonsense_fg = SalienceTheme.build(ground: ground, foreground_l: nonsense_fg_al)
      without_fg = SalienceTheme.build(ground: ground, foreground_l: nil)

      assert hex(with_nonsense_fg.colors.emphasis) == hex(without_fg.colors.emphasis)
    end

    test "nonsense-fg guard: a fg lighter than a light ground is ignored" do
      ground = 0.95
      nonsense_fg_al = 0.99

      with_nonsense_fg = SalienceTheme.build(ground: ground, foreground_l: nonsense_fg_al)
      without_fg = SalienceTheme.build(ground: ground, foreground_l: nil)

      assert hex(with_nonsense_fg.colors.emphasis) == hex(without_fg.colors.emphasis)
    end

    test "absent :foreground_l (no override, no cached record) leaves build unchanged" do
      Capabilities.reset_cache()
      on_exit(fn -> Capabilities.reset_cache() end)

      via_default = SalienceTheme.build(ground: 0.2)
      via_explicit_nil = SalienceTheme.build(ground: 0.2, foreground_l: nil)

      assert hex(via_default.colors.emphasis) == hex(via_explicit_nil.colors.emphasis)
    end
  end
end
