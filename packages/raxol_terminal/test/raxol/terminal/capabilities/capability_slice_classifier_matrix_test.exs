defmodule Raxol.Terminal.Capabilities.CapabilitySliceClassifierMatrixTest do
  @moduledoc """
  CAP-P-01: the fixture golden matrix. Every
  `test/fixtures/capability/capture/*.json` replays end-to-end through
  Probe/Classifier and is asserted byte-exactly against its `expected`
  record and `expected_tier` ladder golden. Dropping in a new T0 capture
  adds a regression with zero code (04 design §2).

  Plus classifier-level cases: CAP-P-08/09, CAP-N-05/06/12.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Capabilities.{Classifier, Ladder, Probe, ReplyScanner}
  alias Raxol.Test.CapabilityFixtures

  for path <- CapabilityFixtures.all() do
    @path path
    test "CAP-P-01 matrix golden: #{Path.basename(path, ".json")}" do
      fixture = CapabilityFixtures.load!(@path)
      env = CapabilityFixtures.env(fixture)

      probe = Probe.new(env, budget_ms: 100)
      {probe, _actions} = Probe.step(probe, :start)
      {probe, input_actions} = Probe.step(probe, {:input, fixture["reply"]})
      # one clock far past deadline + extension closes every window
      {probe, _actions} = Probe.step(probe, {:clock, 1_000})

      assert {:done, caps} = Probe.result(probe)

      for {field, expected} <- CapabilityFixtures.expected_assertions(fixture) do
        actual = Map.fetch!(caps, field)

        assert actual == expected,
               "#{Path.basename(@path)}: expected #{field}=" <>
                 "#{inspect(expected)}, got #{inspect(actual)}"
      end

      assert Ladder.select(caps, env) ==
               {:ok, CapabilityFixtures.expected_tier(fixture)}

      case fixture["expected_leak"] do
        nil ->
          :ok

        expected_leak ->
          leaked =
            for {:leak_free, bytes} <- input_actions, into: "", do: bytes

          assert leaked == expected_leak,
                 "#{Path.basename(@path)}: leak mismatch"
      end
    end
  end

  defp classify(reply, env, opts \\ []) do
    {acc, _leak} = ReplyScanner.scan(reply, ReplyScanner.new())
    Classifier.classify(acc, env, opts)
  end

  describe "CAP-P-08: identity fallback" do
    test "no XTVERSION, DA1-only -> nil identity, core tier, no crash" do
      caps = classify("\e[?1;2c", %{"TERM" => "xterm-256color"})
      assert caps.identity == nil
      assert caps.tier == :core
    end

    test "DA2 without XTVERSION records DA2 provenance" do
      caps = classify("\e[>1;10;0c\e[?62;c", %{})
      assert caps.identity == nil
      assert caps.source.identity == :da2
    end
  end

  describe "CAP-P-09: truecolor priority order" do
    test "XTGETTCAP RGB outranks the env seed" do
      # 524742 = hex("RGB"); reply carries a value -> confirmed truecolor
      reply = "\eP1+r524742=382f382f38\e\\\e[?62;c"
      caps = classify(reply, %{})
      assert caps.truecolor == true
      assert caps.source.truecolor == :xtgettcap
    end

    test "$COLORTERM alone is trusted only as a seed" do
      caps = classify("\e[?62;c", %{"COLORTERM" => "truecolor"})
      assert caps.truecolor == true
      assert caps.source.truecolor == :env
    end

    test "neither -> false" do
      caps = classify("\e[?62;c", %{})
      assert caps.truecolor == false
      assert caps.source.truecolor == :default
    end
  end

  describe "CAP-N-05: the Alacritty lie" do
    test "2026 stuck at 2 + Alacritty identity -> supported, no_verify" do
      reply = "\e[?2026;2$y\eP>|Alacritty 0.13.2\e\\\e[?6c"
      caps = classify(reply, %{"TERM" => "alacritty"})

      assert caps.sync_output == true
      assert caps.source.sync_output == :decrqm
      assert :no_verify_2026 in caps.quirks
    end

    test "2026=2 on a non-Alacritty terminal carries no quirk" do
      reply = "\e[?2026;2$y\eP>|kitty(0.32.2)\e\\\e[?62;c"
      caps = classify(reply, %{})
      assert caps.sync_output == true
      refute :no_verify_2026 in caps.quirks
    end
  end

  describe "CAP-N-06: tmux conservative clamp" do
    test "inside tmux: clamped record, $TERM=screen never trusted" do
      env = %{"TMUX" => "/tmp/tmux-501/default,1,0", "TERM" => "screen"}
      # even a (forwarded/garbled) positive 2026 reply is clamped
      caps = classify("\e[?2026;1$y\e[?62;c", env)

      assert caps.multiplexer == :tmux
      assert caps.sync_output == false
      assert caps.source.sync_output == :tmux_clamp
      assert :multiplexer_conservative_clamp in caps.quirks
    end

    test "$TERM=screen without $TMUX still clamps (GNU screen)" do
      caps = classify("\e[?62;c", %{"TERM" => "screen-256color"})
      assert caps.multiplexer == :screen
      assert :multiplexer_conservative_clamp in caps.quirks
    end

    test "rich caps inside tmux are capped to modern" do
      env = %{"TMUX" => "/tmp/tmux-501/default,1,0"}
      caps = classify("\e[?31u\e[?2026;1$y\e[?62;c", env)
      assert caps.tier == :modern
      assert caps.kitty_keyboard == nil
      assert caps.kitty_graphics == false
    end
  end

  describe "CAP-N-12: Windows platform gate" do
    test "2048/pixel gated by platform, not by DECRQM absence" do
      # the wire even claims 2048 support -- the platform gate wins
      reply = "\e[?2048;1$y\e[6;20;10t\e[?62;c"
      caps = classify(reply, %{}, platform: :windows)

      assert caps.in_band_resize == false
      assert caps.source.in_band_resize == :platform
      assert caps.cell_px == nil
      assert :windows_platform_gates in caps.quirks
    end

    test "same wire on unix keeps the caps" do
      reply = "\e[?2048;1$y\e[6;20;10t\e[?62;c"
      caps = classify(reply, %{})
      assert caps.in_band_resize == true
      assert caps.cell_px == {10, 20}
    end
  end

  describe "native-palette-riding: background/foreground (osc11/osc10 no longer discarded)" do
    test "OSC 11 populates background with :osc11 provenance" do
      caps = classify("\e]11;rgb:2020/2020/2020\a\e[?62;c", %{})
      assert caps.background == {32, 32, 32}
      assert caps.source.background == :osc11
    end

    test "OSC 10 populates foreground with :osc10 provenance" do
      caps = classify("\e]10;rgb:f0f0/f0f0/f0f0\a\e[?62;c", %{})
      assert caps.foreground == {240, 240, 240}
      assert caps.source.foreground == :osc10
    end

    test "silence on both leaves background/foreground nil with :default provenance" do
      caps = classify("\e[?62;c", %{})
      assert caps.background == nil
      assert caps.foreground == nil
      assert caps.source.background == :default
      assert caps.source.foreground == :default
    end

    test "an invalid OSC 11/10 reply is never mistaken for a color" do
      caps = classify("\e]11;garbage\a\e]10;garbage\a\e[?62;c", %{})
      assert caps.background == nil
      assert caps.foreground == nil
    end
  end

  describe "native-palette-riding: color_depth ladder" do
    test "$NO_COLOR non-empty wins over everything else" do
      reply = "\eP1+r524742=382f382f38\e\\\e[?62;c"

      env = %{
        "NO_COLOR" => "1",
        "COLORTERM" => "truecolor",
        "TERM" => "xterm-256color"
      }

      caps = classify(reply, env)
      assert caps.color_depth == :none
      assert caps.source.color_depth == :no_color
    end

    test "an empty $NO_COLOR is treated as unset (per the standard)" do
      caps = classify("\e[?62;c", %{"NO_COLOR" => "", "COLORTERM" => "truecolor"})
      assert caps.color_depth == :truecolor
      assert caps.source.color_depth == :colorterm
    end

    test "XTGETTCAP RGB outranks $COLORTERM" do
      # 524742 = hex("RGB")
      reply = "\eP1+r524742=382f382f38\e\\\e[?62;c"
      caps = classify(reply, %{"COLORTERM" => "truecolor"})
      assert caps.color_depth == :truecolor
      assert caps.source.color_depth == :xtgettcap
    end

    test "$COLORTERM=24bit alone seeds truecolor" do
      caps = classify("\e[?62;c", %{"COLORTERM" => "24bit"})
      assert caps.color_depth == :truecolor
      assert caps.source.color_depth == :colorterm
    end

    test "$TERM=*-256color with no truecolor signal -> :ansi256" do
      caps = classify("\e[?62;c", %{"TERM" => "xterm-256color"})
      assert caps.color_depth == :ansi256
      assert caps.source.color_depth == :term
    end

    test "no signal at all floors to :ansi16" do
      caps = classify("\e[?62;c", %{"TERM" => "xterm"})
      assert caps.color_depth == :ansi16
      assert caps.source.color_depth == :default
    end
  end

  describe "native-palette-riding: $COLORFGBG polarity seed" do
    test "2-field form: bg in {0..6,8} -> :dark" do
      caps = classify("\e[?62;c", %{"COLORFGBG" => "15;0"})
      assert caps.polarity_seed == :dark
      assert caps.source.polarity_seed == :colorfgbg
    end

    test "2-field form: bg in {7,15} -> :light" do
      caps = classify("\e[?62;c", %{"COLORFGBG" => "0;15"})
      assert caps.polarity_seed == :light
      assert caps.source.polarity_seed == :colorfgbg
    end

    test "urxvt 3-field form takes the LAST field as bg" do
      caps = classify("\e[?62;c", %{"COLORFGBG" => "15;default;0"})
      assert caps.polarity_seed == :dark
      assert caps.source.polarity_seed == :colorfgbg
    end

    test "bg in the 9-14 dead zone -> nil (still :colorfgbg provenance)" do
      caps = classify("\e[?62;c", %{"COLORFGBG" => "0;12"})
      assert caps.polarity_seed == nil
      assert caps.source.polarity_seed == :colorfgbg
    end

    test "malformed (non-numeric) bg field -> nil, never crashes" do
      caps = classify("\e[?62;c", %{"COLORFGBG" => "default;default"})
      assert caps.polarity_seed == nil
      assert caps.source.polarity_seed == :colorfgbg
    end

    test "unset $COLORFGBG -> nil with :default provenance" do
      caps = classify("\e[?62;c", %{})
      assert caps.polarity_seed == nil
      assert caps.source.polarity_seed == :default
    end

    test "empty $COLORFGBG is treated as unset" do
      caps = classify("\e[?62;c", %{"COLORFGBG" => ""})
      assert caps.polarity_seed == nil
      assert caps.source.polarity_seed == :default
    end
  end

  describe "mode 2027 -> unicode axis" do
    test "2027 supported flips grapheme_width to :mode_2027" do
      caps = classify("\e[?2027;1$y\e[?62;c", %{})
      assert caps.grapheme_width == :mode_2027
      assert caps.unicode == :grapheme
    end
  end
end
