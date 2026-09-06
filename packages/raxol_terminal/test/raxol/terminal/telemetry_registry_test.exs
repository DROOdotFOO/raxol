defmodule Raxol.Terminal.TelemetryRegistryTest do
  @moduledoc """
  Holds `Raxol.Terminal.Telemetry`'s registry against the telemetry events
  actually emitted from this package's `lib/`, so a new event cannot be added
  without someone classifying it.

  This is the load-bearing test of the whole mechanism. The classification is
  what makes an event enforceable (`Raxol.Core.Telemetry.InvariantSentinel`
  arms `invariant_events/0`), so an unclassified event is an event that
  silently opts out of enforcement -- which is the state a sibling package was
  already in when an emitted-and-logged impossible state shipped anyway.

  The scan is `Raxol.Core.Telemetry.Invariants.scan_lib!/1`, shared by every
  package that carries a registry, so the parse rules cannot drift per package.
  It reads emit sites, not prose, and it can only see fully-literal names --
  hence the dynamic-family handling below.

  Includes a vacuity guard: a moved `lib/` must fail loudly rather than pass
  empty.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Telemetry.Invariants
  alias Raxol.Terminal.Telemetry

  @lib_root Path.expand("../../../lib", __DIR__)
  @sources Path.wildcard(Path.join(@lib_root, "**/*.ex"))
  @emitted Invariants.scan_lib!(@lib_root)

  for source <- @sources do
    @external_resource source
  end

  test "the lib tree was found, so the assertions below are not vacuous" do
    assert length(@sources) > 100,
           "found only #{length(@sources)} modules under #{@lib_root}; if the " <>
             "package layout moved, point this test at its new home rather " <>
             "than deleting it"

    assert length(@emitted) >= 9,
           "scan_lib!/1 found only #{length(@emitted)} emitted telemetry " <>
             "events under #{@lib_root} (#{inspect(@emitted)}), which is " <>
             "fewer than this package is known to emit; the scan is broken, " <>
             "not the registry"
  end

  test "every telemetry event emitted from lib/ is classified" do
    unclassified = Enum.reject(@emitted, &Telemetry.classification/1)

    assert unclassified == [], """
    These telemetry events are emitted from #{@lib_root} but Raxol.Terminal.Telemetry
    does not classify them:

        #{inspect(unclassified, pretty: true)}

    Classify each one as :invariant (can only fire if this library is wrong),
    :peer (a misbehaving remote party caused it) or :operational (normal life
    -- input, user config, a clock tick, a caller's own API call), with a
    comment saying why. Err toward :peer/:operational: a false invariant makes
    the suite flaky, which is worse than a missed one.
    """
  end

  test "the registry claims no event this package does not emit" do
    # A key the scan did not see is legitimate only when it is a leaf of a
    # declared dynamic family: `TraceContext.span/3` builds `:start`, `:stop`
    # and `:exception` at runtime, so those names exist at no emit site for
    # scan_lib!/1 to read, yet they must be spelled out to be enforceable.
    phantom =
      for event <- Map.keys(Telemetry.events()),
          event not in @emitted,
          not Enum.any?(Telemetry.dynamic_families(), &List.starts_with?(event, &1)),
          do: event

    assert phantom == [], """
    Raxol.Terminal.Telemetry classifies events that are neither emitted from
    #{@lib_root} nor leaves of a declared dynamic family:

        #{inspect(phantom, pretty: true)}

    A stale entry reads as coverage this package does not have -- either the
    emit site moved out of lib/ or the entry should go.
    """
  end

  test "every declared dynamic family is actually emitted as a span prefix" do
    orphans = Enum.reject(Telemetry.dynamic_families(), &(&1 in @emitted))

    assert orphans == [], """
    These dynamic families are declared but no emit site under #{@lib_root}
    uses them as a prefix: #{inspect(orphans, pretty: true)}. A dynamic family
    suppresses the completeness check for every name beneath it, so a stale
    one is a hole in the guard rather than a harmless leftover.
    """
  end

  test "every classification is one of the three known verdicts" do
    bogus =
      Enum.reject(Telemetry.events(), fn {_event, class} ->
        class in [:invariant, :peer, :operational]
      end)

    assert bogus == [],
           "unknown classification(s) in Raxol.Terminal.Telemetry: #{inspect(bogus)}"
  end

  test "invariant_events/0 is exactly the :invariant subset of events/0" do
    derived =
      Telemetry.events()
      |> Enum.filter(fn {_event, class} -> class == :invariant end)
      |> Enum.map(fn {event, _class} -> event end)
      |> Enum.sort()

    assert Telemetry.invariant_events() == derived
  end

  test "a span's :exception leaf outranks its :operational family" do
    # The registry depends on this precedence: the three SafeEmulator span
    # prefixes are declared dynamic (so :start/:stop are operational) while
    # their :exception leaves are classified :invariant by exact key. If
    # classification/1 ever preferred the family, the only enforceable events
    # in this package would silently become operational.
    for prefix <- [
          [:raxol, :emulator, :input],
          [:raxol, :emulator, :sequence],
          [:raxol, :emulator, :resize]
        ] do
      assert Telemetry.classification(prefix ++ [:exception]) == :invariant
      assert Telemetry.classification(prefix ++ [:start]) == :operational
      assert Telemetry.classification(prefix ++ [:stop]) == :operational
    end
  end
end
