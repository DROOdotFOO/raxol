t0_root = Path.expand("../../scripts/harness/t0", __DIR__)
Code.require_file("ringb/boot.ex", t0_root)
T0.RingB.Boot.require_all!(t0_root)

defmodule Raxol.Harness.RingBKittyTest do
  @moduledoc """
  Unit RB, kitty driver (remote control over a Unix socket). Tier-1, but
  documented as best-effort/flaky when launched detached-headless — this
  suite treats a `spawn_session` failure as a clean skip, never a
  failure, matching the unit's own brief ("make it robust... or mark
  best-effort/skip").
  """

  use ExUnit.Case, async: false

  alias T0.RingB.Drivers.Kitty
  alias T0.RingB.{Guard, Measurements}

  @moduletag :ring_b
  @moduletag :macos_gui
  @moduletag :unix_only

  @probes_dir Path.expand("../../scripts/harness/t0/probes", __DIR__)

  setup do
    if Kitty.available?() do
      case Kitty.spawn_session([]) do
        {:ok, session} ->
          on_exit(fn ->
            Guard.safe_teardown(Kitty, session, "ringb-kitty-test")
          end)

          [session: session]

        {:error, reason} ->
          {:skip,
           "kitty spawn_session failed (best-effort driver): #{inspect(reason)}"}
      end
    else
      {:skip, "kitty not installed in this environment"}
    end
  end

  test "C1 -- region + footer pin survives an overflowing stream", %{
    session: session
  } do
    row = Measurements.measure_c1(Kitty, session, @probes_dir)
    assert row.verdict == "pass", row.notes
  end

  test "C2 -- 100-line overflow is fully recoverable via `kitty @ get-text`", %{
    session: session
  } do
    row = Measurements.measure_c2(Kitty, session, @probes_dir)
    assert row.verdict == "fed", row.notes
  end

  test "close-window teardown leaves no window/process behind", %{
    session: session
  } do
    row = Measurements.measure_c1(Kitty, session, @probes_dir)
    Guard.safe_teardown(Kitty, session, row.marker)
    refute Kitty.still_open?(session)
  end
end
