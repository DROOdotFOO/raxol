defmodule Raxol.TelemetryRegistryTest do
  @moduledoc """
  Holds `Raxol.Telemetry`'s registry against the telemetry events actually
  emitted from this project's `lib/`, so a new event cannot be added without
  someone classifying it.

  This is the load-bearing test of the whole mechanism. The classification is
  what makes an event enforceable (`Raxol.Core.Telemetry.InvariantSentinel`
  arms `invariant_events/0`), so an unclassified event is an event that
  silently opts out of enforcement -- exactly the state that let a
  detected-and-logged defect ship in `raxol_agent_client_protocol`.

  The registry is read from source rather than restated here; restating it
  would reintroduce the second source of truth this is meant to remove. Same
  mechanic as `formatter_delegation_test.exs` (which parses the CI matrix out
  of `.github/workflows/ci-unified.yml`), including the vacuity guard: a moved
  `lib/` must fail loudly rather than pass empty.

  The scan is AST-based (`Raxol.Core.Telemetry.Invariants.scan_lib!/1`), so it
  sees emit sites only -- an event named in a moduledoc, or subscribed to in an
  `attach_many/4` list, is not this project's event to classify.
  `Raxol.Performance.AdaptiveOptimizer` and friends subscribe to a dozen
  `raxol_terminal` events that would otherwise land here as false demands.

  Scanning 691 modules costs ~0.8s once, at this module's compile time; the
  attributes below hold the result so no test repeats it. No
  `@external_resource` is declared: ExUnit recompiles test files on every run
  anyway, so it would buy nothing but a longer dependency graph.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Telemetry.Invariants

  @lib_root Path.expand("../../lib", __DIR__)
  @sources Path.wildcard(Path.join(@lib_root, "**/*.ex"))
  @emitted Invariants.scan_lib!(@lib_root)
  @source_text Enum.map_join(@sources, "\n", &File.read!/1)

  test "the lib tree was found, so the assertions below are not vacuous" do
    assert length(@sources) > 300,
           "found only #{length(@sources)} modules under #{@lib_root}; if the " <>
             "project layout moved, point this test at its new home rather " <>
             "than deleting it"

    assert length(@emitted) > 10,
           "found only #{length(@emitted)} emitted telemetry events under " <>
             "#{@lib_root}, which is fewer than this project is known to " <>
             "emit; the scan is broken, not the registry"
  end

  test "every telemetry event emitted from lib/ is classified in Raxol.Telemetry" do
    unclassified = Enum.reject(@emitted, &Raxol.Telemetry.classification(&1))

    assert unclassified == [], """
    These telemetry events are emitted from #{@lib_root} but Raxol.Telemetry
    classifies neither them nor a dynamic family covering them:

        #{inspect(unclassified, pretty: true)}

    Classify each one as :invariant (can only fire if Raxol itself is wrong),
    :peer (a misbehaving remote producer caused it) or :operational (normal
    life -- lifecycle, load shedding, the terminal or filesystem refusing
    something, invalid user-supplied style/theme input), with a comment saying
    why. Err toward :peer/:operational: a false invariant makes the suite
    flaky, which is worse than a missed one.
    """
  end

  test "the registry claims no static event this project does not emit" do
    phantom = Map.keys(Raxol.Telemetry.events()) -- @emitted

    assert phantom == [], """
    Raxol.Telemetry classifies events that no emit site in #{@lib_root}
    produces: #{inspect(phantom, pretty: true)}. A stale entry reads as
    coverage this project does not have -- either the emit site moved to a
    package (which carries its own registry) or the entry should go.
    """
  end

  test "every dynamic family is still built somewhere in lib/" do
    # A dynamic family is an EXCUSE: the completeness test above accepts any
    # event under it. A family whose emit site is gone would go on excusing
    # future events under that prefix forever, so it has to keep earning its
    # place. Runtime-built names are not literals, so this matches the
    # written prefix instead -- whitespace-tolerant, so a formatter-wrapped
    # emit still counts.
    stale =
      Enum.reject(Raxol.Telemetry.dynamic_families(), fn family ->
        pattern =
          family
          |> Enum.map_join("\\s*,\\s*", fn segment -> ":#{segment}" end)
          |> then(&Regex.compile!("\\[\\s*#{&1}\\s*,"))

        Regex.match?(pattern, @source_text)
      end)

    assert stale == [], """
    Raxol.Telemetry declares dynamic families no longer built in
    #{@lib_root}: #{inspect(stale, pretty: true)}.
    """
  end
end
