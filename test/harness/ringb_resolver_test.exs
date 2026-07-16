t0_root = Path.expand("../../scripts/harness/t0", __DIR__)
Code.require_file("ringb/boot.ex", t0_root)
T0.RingB.Boot.require_all!(t0_root)

defmodule Raxol.Harness.RingBResolverTest do
  @moduledoc """
  Unit RB end-to-end: runs the full `T0.RingB.Runner` matrix (every
  installed, drivable terminal x every automatable claim) and asserts
  the D-PA resolver reaches a real, non-trivial resolution from it --
  the thing this whole unit exists to produce.

  The honest expectation, spelled out so a future reader doesn't mistake
  this for a bug: `dpa` itself is structurally `"pending"` even with
  every automatable terminal green, because Ghostty (tier-1, per the
  resolver's own `@tier1` list) has no capture primitive at all (see
  `ringb_ghostty_test.exs`) and can only reach ground truth via a human
  screenshot pass -- `verdict_resolver.exs`'s rule 6 (the two-terminal
  floor) requires ALL FOUR tier-1 terminals measured before it will ever
  say a definitive `"A"/"B"/"C"`. What THIS unit retires is the floor
  BELOW that: once >= 2 tier-1 terminals are measured, the resolver
  stops refusing outright (`provisional: nil`) and produces a real,
  paste-able `provisional` suggestion from the measured subset -- that
  transition is what this test pins.

  Opens and closes many real GUI windows (one per driver x claim) --
  budget several minutes for this test alone.
  """

  use ExUnit.Case, async: false

  alias T0.RingB.Runner

  @moduletag :ring_b
  @moduletag :macos_gui
  @moduletag :unix_only

  @tag timeout: 180_000
  test "the automated matrix resolves at least a provisional D-PA from >= 2 tier-1 terminals" do
    t0_root = Path.expand("../../scripts/harness/t0", __DIR__)
    %{results: results, resolver: resolver} = Runner.run(t0_root)

    real_rows = Enum.reject(results, &Map.get(&1, :skip))

    assert real_rows != [],
           "expected at least one installed, drivable terminal in this environment"

    measured = resolver["tier1_terminals_measured"] || []

    assert length(measured) >= 2,
           "expected >= 2 tier-1 terminals measured (iTerm2/WezTerm/kitty are all " <>
             "automatable on this machine); got: #{inspect(measured)} -- resolver: #{inspect(resolver)}"

    # The two-terminal floor has been cleared: this is no longer the
    # structural refusal ("fewer than 2 tier-1 terminals... two-terminal
    # floor refuses even a provisional D-PA") -- a real subset suggestion
    # must be present.
    refute is_nil(resolver["provisional"]),
           "expected a provisional suggestion once >= 2 tier-1 terminals are measured, got nil " <>
             "(resolver: #{inspect(resolver)})"

    assert resolver["provisional"]["dpa"] in ["A", "B", "C"]

    # No disqualifying C1/C3 failure or C2=lost should show up on a clean
    # measured run -- "no_go" would mean a real regression was found.
    refute resolver["go"] == "no_go",
           "unexpected no_go: #{resolver["go_reason"]}"

    # Ghostty structurally cannot reach ground truth from this unit
    # (no capture primitive) -- it must be the ONLY thing keeping dpa
    # from being definitive, never silently dropped from the picture.
    assert "ghostty" in (resolver["tier1_terminals_missing"] || []),
           "ghostty should remain the documented missing tier-1 terminal"
  end
end
