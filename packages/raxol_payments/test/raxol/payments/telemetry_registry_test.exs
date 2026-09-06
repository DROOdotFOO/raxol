defmodule Raxol.Payments.TelemetryRegistryTest do
  @moduledoc """
  Holds `Raxol.Payments.Telemetry`'s registry against the telemetry events this
  package's `lib/` actually emits, so a new event cannot be added without
  someone classifying it.

  This is the load-bearing test of the mechanism in this package. The
  classification is what makes an event enforceable
  (`Raxol.Core.Telemetry.InvariantSentinel` arms `invariant_events/0`), so an
  unclassified event is an event that silently opts out of enforcement --
  exactly the state that let an emitted-and-logged impossible state ship
  anyway.

  It matters more here than anywhere else in the repo even though this package
  classifies nothing as `:invariant` today: the events name real money moving,
  and the next guard someone adds to the settlement path is the one that must
  not be allowed to be inert.

  The source of truth is the source: `Invariants.scan_lib!/1` re-derives the
  emitted set from `lib/` rather than restating it here, which would
  reintroduce the second source of truth this test exists to prevent. The
  vacuity guard is deliberate -- a moved `lib/` must fail loudly rather than
  pass empty.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Telemetry.Invariants
  alias Raxol.Payments.Telemetry

  @lib_root Path.expand("../../../lib", __DIR__)
  @sources Path.wildcard(Path.join(@lib_root, "**/*.ex"))

  for source <- @sources do
    @external_resource source
  end

  @emitted Invariants.scan_lib!(@lib_root)

  # Every event known to have an emit site as of this test being written. The
  # floor exists only so a scanner that silently stops matching cannot turn the
  # assertions below into no-ops; it is not a second registry.
  @known_emit_count 13

  test "the lib tree was found and scanned, so the assertions below are not vacuous" do
    assert File.dir?(@lib_root),
           "lib/ not found at #{@lib_root} -- this test's path assumption moved"

    assert length(@sources) > 50,
           "only #{length(@sources)} source files under #{@lib_root}; the scan is too narrow"

    assert length(@emitted) >= @known_emit_count,
           "scanner found only #{length(@emitted)} emitted events, expected at least " <>
             "#{@known_emit_count}: #{inspect(@emitted)}"
  end

  test "every telemetry event emitted in lib/ is classified in Raxol.Payments.Telemetry" do
    unclassified = Enum.reject(@emitted, &Telemetry.classification(&1))

    assert unclassified == [],
           """
           These telemetry events are emitted by lib/ but are not classified in
           Raxol.Payments.Telemetry:

           #{Enum.map_join(unclassified, "\n", &"  #{inspect(&1)}")}

           Add each one to the `events:` map with a comment saying WHY it lands
           where it does. Read its emit site first: if a peer, the network, the
           chain, the filesystem, the clock or a user can cause it, it is NOT an
           invariant.
           """
  end

  test "the registry claims no event this package does not emit" do
    stale = Map.keys(Telemetry.events()) -- @emitted

    assert stale == [],
           """
           These events are classified in Raxol.Payments.Telemetry but no longer
           have an emit site in lib/:

           #{Enum.map_join(stale, "\n", &"  #{inspect(&1)}")}

           Drop them, or declare the family in `dynamic:` if the final segment is
           built at runtime.
           """
  end

  test "every classification is one of the three known verdicts" do
    for {event, class} <- Telemetry.events() do
      assert class in [:invariant, :peer, :operational],
             "#{inspect(event)} is classified #{inspect(class)}, which is not a verdict"
    end
  end

  test "invariant_events/0 is exactly the :invariant subset of events/0" do
    expected =
      Telemetry.events()
      |> Enum.filter(fn {_event, class} -> class == :invariant end)
      |> Enum.map(fn {event, _class} -> event end)
      |> Enum.sort()

    assert Telemetry.invariant_events() == expected
  end

  # Documents the classification finding as an assertion rather than as prose
  # only, so promoting an event to :invariant is a deliberate act that shows up
  # in a diff here alongside the sentinel wiring it requires.
  test "this package classifies nothing as :invariant, and the sentinel is therefore inert" do
    assert Telemetry.invariant_events() == [],
           """
           An :invariant event now exists in raxol_payments:

           #{Enum.map_join(Telemetry.invariant_events(), "\n", &"  #{inspect(&1)}")}

           That is a real change of posture, not a typo. Wire
           `use Raxol.Core.Telemetry.InvariantSentinel, registry: Raxol.Payments.Telemetry`
           into the async: false suites that drive that event's path, then update
           this test.
           """
  end

  test "no dynamic family is classified :invariant" do
    for family <- Telemetry.dynamic_families() do
      refute Telemetry.classification(family) == :invariant,
             "#{inspect(family)} is a dynamic family; the sentinel cannot subscribe to a " <>
               "name it cannot spell"
    end
  end
end
