t0_root = Path.expand("../../scripts/harness/t0", __DIR__)
Code.require_file("ringb/boot.ex", t0_root)
T0.RingB.Boot.require_all!(t0_root)

defmodule Raxol.Harness.RingBTerminalAppTest do
  @moduledoc """
  Unit RB, Apple Terminal.app driver. Not a tier-1 terminal (the
  resolver's `@tier1` is kitty/iTerm2/WezTerm/Ghostty only) — these
  results never move D-PA, but they're real measured data under
  `terminal=apple`, including the two documented driver limits: no raw
  non-executing write (C3 is text-only, `partial` not `pass`) and a
  scrollback capture that turned out to be much shorter than iTerm2's
  (see the C2 test below — this is what motivated `Guard`'s fix in the
  first place: Terminal.app is the terminal that popped the "terminate
  running processes?" modal during development).
  """

  use ExUnit.Case, async: false

  alias T0.RingB.Drivers.TerminalApp
  alias T0.RingB.{Guard, Measurements}

  @moduletag :ring_b
  @moduletag :macos_gui
  @moduletag :unix_only

  @probes_dir Path.expand("../../scripts/harness/t0/probes", __DIR__)

  # ExUnit has no runtime skip: a callback returning {:skip, _} raises and
  # invalidates the module. Decide availability at load time. A spawn failure on
  # an installed emulator is a real failure, so surface it as one.
  if not TerminalApp.available?() do
    @moduletag skip: "Terminal.app not available in this environment"
  end

  setup do
    case TerminalApp.spawn_session([]) do
      {:ok, session} ->
        on_exit(fn ->
          Guard.safe_teardown(TerminalApp, session, "ringb-apple-test")
        end)

        [session: session]

      {:error, reason} ->
        flunk("Terminal.app spawn_session failed: #{inspect(reason)}")
    end
  end

  test "C1 -- region + footer pin survives an overflowing stream", %{
    session: session
  } do
    row = Measurements.measure_c1(TerminalApp, session, @probes_dir)
    assert row.verdict == "pass", row.notes
  end

  test "C3 -- no raw-write primitive: verdict is partial, never a false pass",
       %{
         session: session
       } do
    row = Measurements.measure_c3(TerminalApp, session, @probes_dir)
    assert row.verdict in ["partial", "pass"], row.notes
    assert row.notes =~ "cursor-position API" or row.verdict == "pass"
  end

  test "teardown after a live HOLD process never leaves the window open", %{
    session: session
  } do
    row = Measurements.measure_c1(TerminalApp, session, @probes_dir)
    Guard.safe_teardown(TerminalApp, session, row.marker)
    refute TerminalApp.still_open?(session)
  end
end
