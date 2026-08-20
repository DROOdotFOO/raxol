t0_root = Path.expand("../../scripts/harness/t0", __DIR__)
Code.require_file("ringb/boot.ex", t0_root)
T0.RingB.Boot.require_all!(t0_root)

defmodule Raxol.Harness.RingBWeztermTest do
  @moduledoc """
  Unit RB, WezTerm driver (`wezterm cli`). Tier-1. `wezterm cli list`
  exposes a real `cursor_x`/`cursor_y` field per pane, so this is the one
  driver with a genuine cursor-position API rather than marker-injection
  inference for C3 -- covered separately from the shared footer-based
  assertion the other drivers use.
  """

  use ExUnit.Case, async: false

  alias T0.RingB.Drivers.Wezterm
  alias T0.RingB.{Guard, Measurements}

  @moduletag :ring_b
  @moduletag :macos_gui
  @moduletag :unix_only

  @probes_dir Path.expand("../../scripts/harness/t0/probes", __DIR__)

  # ExUnit has no runtime skip: a callback returning {:skip, _} raises and
  # invalidates the module. Decide availability at load time. A spawn failure on
  # an installed emulator is a real failure, so surface it as one.
  if not Wezterm.available?() do
    @moduletag skip: "wezterm not installed in this environment"
  end

  setup do
    case Wezterm.spawn_session([]) do
      {:ok, session} ->
        on_exit(fn ->
          Guard.safe_teardown(Wezterm, session, "ringb-wezterm-test")
        end)

        [session: session]

      {:error, reason} ->
        flunk("wezterm spawn_session failed: #{inspect(reason)}")
    end
  end

  test "C2 -- 100-line overflow is fully recoverable via `wezterm cli get-text`",
       %{
         session: session
       } do
    row = Measurements.measure_c2(Wezterm, session, @probes_dir)
    assert row.verdict == "fed", row.notes
  end

  test "C4 is not attempted -- wezterm-cli has no resize subcommand (documented, not guessed)" do
    refute "C4" in Measurements.available_claims(Wezterm)
  end

  test "close-pane teardown leaves no pane behind", %{session: session} do
    row = Measurements.measure_c1(Wezterm, session, @probes_dir)
    Guard.safe_teardown(Wezterm, session, row.marker)
    refute Wezterm.still_open?(session)
  end
end
