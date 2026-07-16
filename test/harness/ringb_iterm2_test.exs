t0_root = Path.expand("../../scripts/harness/t0", __DIR__)
Code.require_file("ringb/boot.ex", t0_root)
T0.RingB.Boot.require_all!(t0_root)

defmodule Raxol.Harness.RingBIterm2Test do
  @moduledoc """
  Unit RB (`docs/proposals/in-flight/t0-runbook.md`'s Ring B, automated):
  drives a real iTerm2 window via `T0.RingB.Drivers.Iterm2` and asserts
  the same claim shapes `scripts/harness/t0/tmux/run_cell.sh` already
  validated against the tmux proxy cell, now against a real tier-1
  terminal via native AppleScript capture (`contents`).

  Opens/closes a real GUI window per test — see `T0.RingB.Guard` for why
  this can never leave a hung confirmation dialog behind. Excluded from
  every default `mix test` invocation (see `test/test_helper.exs`);
  runnable via `mix test --only ring_b` or `mix t0.ringb`.
  """

  use ExUnit.Case, async: false

  alias T0.RingB.Drivers.Iterm2
  alias T0.RingB.{Guard, Measurements}

  @moduletag :ring_b
  @moduletag :macos_gui
  @moduletag :unix_only

  @probes_dir Path.expand("../../scripts/harness/t0/probes", __DIR__)

  setup do
    if Iterm2.available?() do
      case Iterm2.spawn_session([]) do
        {:ok, session} ->
          on_exit(fn ->
            Guard.safe_teardown(Iterm2, session, "ringb-iterm2-test")
          end)

          [session: session]

        {:error, reason} ->
          {:skip, "iTerm2 spawn_session failed: #{inspect(reason)}"}
      end
    else
      {:skip, "iTerm2 not installed in this environment"}
    end
  end

  test "C1 -- region + footer pin survives an overflowing stream", %{
    session: session
  } do
    row = Measurements.measure_c1(Iterm2, session, @probes_dir)
    assert row.verdict == "pass", row.notes
  end

  test "C2 -- 100-line overflow is fully recoverable via native contents", %{
    session: session
  } do
    row = Measurements.measure_c2(Iterm2, session, @probes_dir)
    assert row.verdict == "fed", row.notes
    assert row.observable["tail_window_rows"] > 0
  end

  test "C3 -- print-above cursor protocol lands exactly after the composer text",
       %{
         session: session
       } do
    row = Measurements.measure_c3(Iterm2, session, @probes_dir)
    assert row.verdict == "pass", row.notes
  end

  test "N07 -- rows outside an inverted region stay static (detector-validation)",
       %{
         session: session
       } do
    row = Measurements.measure_n07(Iterm2, session, @probes_dir)
    assert row.observable == "yes", row.notes
  end

  test "C4 -- resize preserves stream content (iTerm2 has a real cell-exact resize primitive)",
       %{
         session: session
       } do
    row = Measurements.measure_c4(Iterm2, session, @probes_dir)
    refute Map.get(row, :skip), "iTerm2 is expected to support resize"
    assert row.verdict in ["reflow", "freeze_clean"], row.notes
  end
end
