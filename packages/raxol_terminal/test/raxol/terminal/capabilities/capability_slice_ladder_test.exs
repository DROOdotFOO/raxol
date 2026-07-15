defmodule Raxol.Terminal.Capabilities.CapabilitySliceLadderTest do
  @moduledoc """
  T3 ladder matrix (04 design §7): LAD-P-01 table, LAD-P-04 tmux tier,
  LAD-N-01 fail-loud misdetection guard, LAD-N-02 forced-downgrade
  telemetry.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Capabilities.Ladder
  alias Raxol.Terminal.Capabilities.Ladder.IncapableModeError

  defp caps(overrides) do
    struct!(Capabilities, overrides)
  end

  describe "LAD-P-01: caps x mode matrix" do
    @matrix [
      # {description, caps overrides, env, expected}
      {"core-minus (not a tty / TERM=dumb)", [tier: :core_minus], %{}, {:ok, :flat}},
      {"tmux, any caps", [tier: :rich, sync_output: true, multiplexer: :tmux], %{},
       {:ok, :tmux_conservative}},
      {"GNU screen", [tier: :modern, multiplexer: :screen], %{}, {:ok, :tmux_conservative}},
      {"Core with verified sync (scroll-region floor proxy), no tmux",
       [tier: :core, sync_output: true], %{}, {:ok, :inline_log}},
      {"Modern, sync, no tmux", [tier: :modern, sync_output: true], %{}, {:ok, :inline_log}},
      {"Rich, no tmux", [tier: :rich], %{}, {:ok, :inline_log}},
      {"Core WITHOUT sync: no inline floor", [tier: :core], %{}, {:ok, :flat}},
      {"capable but RAXOL_FORCE_FLAT", [tier: :modern, sync_output: true],
       %{"RAXOL_FORCE_FLAT" => "1"}, {:ok, :flat}},
      {"capable, RAXOL_FORCE_MODE=flat", [tier: :rich], %{"RAXOL_FORCE_MODE" => "flat"},
       {:ok, :flat}},
      {"forced inline on capable caps", [tier: :modern], %{"RAXOL_FORCE_MODE" => "inline_log"},
       {:ok, :inline_log}},
      {"forced inline UNDER TMUX: rejected", [tier: :modern, multiplexer: :tmux],
       %{"RAXOL_FORCE_MODE" => "inline_log"}, {:error, :incapable}},
      {"forced inline on core-minus: rejected", [tier: :core_minus],
       %{"RAXOL_FORCE_MODE" => "inline_log"}, {:error, :incapable}}
    ]

    for {{desc, overrides, env, expected}, i} <- Enum.with_index(@matrix) do
      @row {overrides, env, expected}
      test "row #{i}: #{desc}" do
        {overrides, env, expected} = @row
        assert Ladder.select(caps(overrides), env) == expected
      end
    end
  end

  describe "LAD-P-04: tmux fixture ends conservative" do
    test "clamped record selects :tmux_conservative" do
      clamped =
        caps(
          tier: :modern,
          sync_output: false,
          multiplexer: :tmux,
          quirks: [:multiplexer_conservative_clamp]
        )

      assert Ladder.select(clamped) == {:ok, :tmux_conservative}
    end
  end

  describe "LAD-N-01: misdetection consequences -- fail loud, never corrupt" do
    test "inline mode forced on incapable caps REFUSES" do
      incapable =
        caps(tier: :core, sync_output: false, multiplexer: :none)

      assert_raise IncapableModeError, fn ->
        Ladder.assert_capable!(:inline_log, incapable)
      end

      # and the non-raising surface returns an error, never proceeds
      assert {:error, :incapable} = Ladder.guard(:inline_log, incapable)
    end

    test "the raise names the offending caps" do
      incapable = caps(tier: :core_minus)

      error =
        assert_raise IncapableModeError, fn ->
          Ladder.assert_capable!(:inline_log, incapable)
        end

      assert error.message =~ "inline_log"
      assert error.message =~ "core_minus"
    end

    test "downgrades are always capable" do
      rich = caps(tier: :rich, sync_output: true)
      assert Ladder.assert_capable!(:flat, rich) == :ok
      assert Ladder.assert_capable!(:tmux_conservative, rich) == :ok
    end
  end

  describe "LAD-N-02: forced downgrade is observable" do
    test "forcing :flat on a capable terminal emits telemetry" do
      handler_id = {__MODULE__, :forced_downgrade}
      parent = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:raxol, :degradation, :forced_downgrade],
          fn _event, _measurements, metadata, _config ->
            send(parent, {:forced_downgrade, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      capable = caps(tier: :rich, sync_output: true)

      assert {:ok, :flat} =
               Ladder.select(capable, %{"RAXOL_FORCE_FLAT" => "1"})

      assert_receive {:forced_downgrade, %{tier: :rich}}
    end

    test "forcing :flat on an incapable terminal is silent (no downgrade)" do
      handler_id = {__MODULE__, :no_downgrade}
      parent = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:raxol, :degradation, :forced_downgrade],
          fn _event, _measurements, metadata, _config ->
            send(parent, {:forced_downgrade_2, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      incapable = caps(tier: :core_minus)

      assert {:ok, :flat} =
               Ladder.select(incapable, %{"RAXOL_FORCE_FLAT" => "1"})

      refute_receive {:forced_downgrade_2, %{tier: :core_minus}}, 10
    end
  end
end
