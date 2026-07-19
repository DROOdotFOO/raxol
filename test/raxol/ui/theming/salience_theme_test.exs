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

    test "record background present -> OKLCH L of that background" do
      Capabilities.cache(%Capabilities{background: {30, 30, 30}})

      {expected_l, _c, _h} = Salience.rgb_to_oklch(30 / 255, 30 / 255, 30 / 255)

      assert_in_delta SalienceTheme.detect_ground(), expected_l, 1.0e-9
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

  describe "detect_foreground_l/0" do
    setup do
      Capabilities.reset_cache()
      on_exit(fn -> Capabilities.reset_cache() end)
      :ok
    end

    test "returns nil when no record is cached" do
      assert SalienceTheme.detect_foreground_l() == nil
    end

    test "returns nil when a record is cached but carries no foreground" do
      Capabilities.cache(%Capabilities{foreground: nil})
      assert SalienceTheme.detect_foreground_l() == nil
    end

    test "returns OKLCH L of the record's foreground when present" do
      Capabilities.cache(%Capabilities{foreground: {230, 230, 230}})

      {expected_l, _c, _h} =
        Salience.rgb_to_oklch(230 / 255, 230 / 255, 230 / 255)

      assert_in_delta SalienceTheme.detect_foreground_l(), expected_l, 1.0e-9
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
