defmodule Raxol.Terminal.CapabilitySliceLadderPropertyTest do
  @moduledoc """
  Ladder fuzz: CAP-F-07 / LAD-P-02 -- `select/2` is total over the
  `%Capabilities{}` state space: always `{:ok, mode}` in the three-mode
  set or `{:error, _}`, never a raise.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Capabilities.Ladder
  alias Raxol.Test.CapabilitySliceGen, as: Gen

  @runs 1000

  # note: no RAXOL_FORCE_FLAT-on-capable case here -- that combination
  # emits the forced-downgrade telemetry asserted (with an attached
  # handler) in the ladder matrix suite; keeping it out avoids
  # cross-test telemetry noise. Totality of the forced-flat branch is
  # covered there.
  @envs [
    %{},
    %{"RAXOL_FORCE_MODE" => "inline_log"},
    %{"RAXOL_FORCE_MODE" => "tmux_conservative"},
    %{"RAXOL_FORCE_MODE" => "garbage"}
  ]

  test "CAP-F-07: select/2 is total over the record state space" do
    modes = Ladder.modes()

    for i <- 1..@runs do
      Gen.seed(i)

      caps = %Capabilities{
        identity: Enum.random([nil, {"kitty", "0.32.2"}, {"x", nil}]),
        tier: Enum.random([:core_minus, :core, :modern, :rich]),
        unicode: Enum.random([:none, :wide, :grapheme]),
        truecolor: Enum.random([true, false]),
        sixel: Enum.random([true, false]),
        kitty_graphics: Enum.random([true, false]),
        kitty_keyboard: Enum.random([nil, 0, 1, 31]),
        sync_output: Enum.random([true, false]),
        grapheme_width: Enum.random([:mode_2027, :measured, :assumed]),
        in_band_resize: Enum.random([true, false]),
        lr_margins: Enum.random([true, false]),
        theme_events: Enum.random([true, false]),
        cell_px: Enum.random([nil, {10, 20}]),
        styled_underline: Enum.random([true, false]),
        multiplexer: Enum.random([:none, :tmux, :screen]),
        quirks: Enum.take_random([:no_verify_2026], :rand.uniform(2) - 1)
      }

      env = Enum.random(@envs)

      case Ladder.select(caps, env) do
        {:ok, mode} ->
          assert mode in modes, "iteration #{i}: unknown mode #{mode}"

          # a selected mode is always capable (select never proposes a
          # mode that assert_capable! would refuse)
          assert Ladder.assert_capable!(mode, caps) == :ok,
                 "iteration #{i}: select proposed an incapable mode"

        {:error, reason} ->
          assert reason == :incapable, "iteration #{i}: #{inspect(reason)}"
      end
    end
  end
end
