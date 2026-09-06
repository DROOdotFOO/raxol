defmodule Raxol.Agent.TelemetryRegistryTest do
  @moduledoc """
  Holds `Raxol.Agent.Telemetry`'s registry against the telemetry event
  literals actually present in this package's `lib/`, so a new event cannot be
  added without someone classifying it.

  This is the load-bearing test of the whole mechanism. The classification is
  what makes an event enforceable (`Raxol.Agent.Test.InvariantSentinel` arms
  `invariant_events/0`), so an unclassified event is an event that silently
  opts out of enforcement -- exactly the state this package was already in,
  where an emitted-and-logged impossible state shipped anyway.

  The source is the registry, so it is read from source rather than restated
  here; restating it would reintroduce the second source of truth. Same
  mechanic as `acp_stream_adapter_coverage_test.exs` (which parses the ACP
  schema's `from_json/1` clauses) and the root suite's
  `formatter_delegation_test.exs` (which parses the CI matrix out of
  `.github/workflows/ci-unified.yml`), including the vacuity guard: a moved
  `lib/` must fail loudly rather than pass empty.

  A doc or comment mention of an event counts as a hit. That is deliberate --
  it costs one registry line and it means a documented event can never be an
  unclassified one.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)
  @sources Path.wildcard(Path.join(@lib_root, "**/*.ex"))

  for source <- @sources do
    @external_resource source
  end

  # Whitespace-tolerant so a formatter-wrapped literal still counts.
  @event_pattern ~r/\[:raxol(?:\s*,\s*:[a-z_]+)+\s*\]/

  @found_events (for source <- @sources,
                     {:ok, content} = File.read(source),
                     [literal] <- Regex.scan(@event_pattern, content),
                     uniq: true do
                   literal
                   |> String.replace(~r/[\[\]\s]/, "")
                   |> String.split(",")
                   |> Enum.map(&String.to_atom(String.trim_leading(&1, ":")))
                 end)

  test "the lib tree was found, so the assertions below are not vacuous" do
    assert length(@sources) > 50,
           "found only #{length(@sources)} modules under #{@lib_root}; if the " <>
             "package layout moved, point this test at its new home rather " <>
             "than deleting it"

    assert length(@found_events) > 10,
           "found only #{length(@found_events)} telemetry event literals under " <>
             "#{@lib_root}, which is fewer than this package is known to emit; " <>
             "the scan is broken, not the registry"
  end

  test "every telemetry event in lib/ is classified in Raxol.Agent.Telemetry" do
    unclassified = @found_events -- Map.keys(Raxol.Agent.Telemetry.events())

    assert unclassified == [], """
    These telemetry events appear in #{@lib_root} but are not classified in
    Raxol.Agent.Telemetry:

        #{inspect(unclassified, pretty: true)}

    Classify each one as :invariant (can only fire if this library is wrong),
    :peer (a misbehaving remote agent/client caused it) or :operational
    (normal life -- filesystem, user config, cache, policy), with a comment
    saying why. Err toward :peer/:operational: a false invariant makes the
    suite flaky, which is worse than a missed one.
    """
  end

  test "the registry claims no event this package does not mention" do
    phantom = Map.keys(Raxol.Agent.Telemetry.events()) -- @found_events

    assert phantom == [], """
    Raxol.Agent.Telemetry classifies events that no longer appear in
    #{@lib_root}: #{inspect(phantom, pretty: true)}. A stale entry reads as
    coverage this package does not have -- either the emit site moved out of
    lib/ or the entry should go.
    """
  end

  test "every classification is one of the three known verdicts" do
    bogus =
      Raxol.Agent.Telemetry.events()
      |> Enum.reject(fn {_event, class} -> class in [:invariant, :peer, :operational] end)

    assert bogus == [],
           "unknown classification(s) in Raxol.Agent.Telemetry: #{inspect(bogus)}"
  end

  test "invariant_events/0 is exactly the :invariant subset of events/0" do
    derived =
      Raxol.Agent.Telemetry.events()
      |> Enum.filter(fn {_event, class} -> class == :invariant end)
      |> Enum.map(fn {event, _class} -> event end)
      |> Enum.sort()

    assert Raxol.Agent.Telemetry.invariant_events() == derived
  end
end
