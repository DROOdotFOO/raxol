defmodule Raxol.Earn.TelemetryRegistryTest do
  @moduledoc """
  Holds `Raxol.Earn.Telemetry`'s registry against the telemetry events actually
  present in this package's `lib/`, so a new event cannot be added without
  someone classifying it.

  This is the load-bearing test of the mechanism. The classification is what
  makes an event enforceable (`Raxol.Core.Telemetry.InvariantSentinel` arms
  `invariant_events/0`), so an unclassified event silently opts out of
  enforcement -- which is how an emitted-and-logged impossible state shipped
  anyway once already.

  Two scans, because they answer different questions:

    * `Raxol.Core.Telemetry.Invariants.scan_lib!/1` finds names in EMIT
      POSITION (including `Raxol.Earn.Xochi.Heartbeat`'s attribute-bound one).
      That set drives both completeness and the phantom-entry check, so an
      entry whose emit site was deleted fails even if a doc line still names it.
    * a text-level literal scan finds every `[:raxol, ...]` atom list mentioned
      anywhere else in `lib/`, which in this package is mostly the `##
      Telemetry` moduledoc sections spelling out concrete members of the
      `dynamic:` families. Pinning those to the registry is the point: the
      moduledocs are where a reader learns the runtime suffixes, and a
      documented name outside every declared family is either a missing
      registry entry or a stale doc.

  Both scans exclude the registry module itself, so it cannot satisfy a check
  by quoting its own keys.

  Dynamic families are covered by prefix, never by exact name: the buyer and
  seller `queue`/`resync` modules build the final segment at run time, so
  demanding a static classification for those names would be permanently red.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Telemetry.Invariants
  alias Raxol.Earn.Telemetry

  @lib_root Path.expand("../../../lib", __DIR__)
  @registry_source Path.join(@lib_root, "raxol/earn/telemetry.ex")
  @sources Path.wildcard(Path.join(@lib_root, "**/*.ex")) -- [@registry_source]

  for source <- [@registry_source | @sources] do
    @external_resource source
  end

  # Whitespace-tolerant so a formatter-wrapped literal still counts. A name with
  # a runtime final segment ([:raxol, :earn, :buyer, :queue, suffix]) is not an
  # atom list and deliberately does not match: those are `dynamic:` families.
  @literal_pattern ~r/\[:raxol(?:\s*,\s*:[a-z_]+)+\s*\]/

  @found_literals (for source <- @sources,
                       {:ok, content} = File.read(source),
                       [literal] <- Regex.scan(@literal_pattern, content),
                       uniq: true do
                     literal
                     |> String.replace(~r/[\[\]\s]/, "")
                     |> String.split(",")
                     |> Enum.map(&String.to_atom(String.trim_leading(&1, ":")))
                   end)

  @static_events Map.keys(Telemetry.events())
  @families Telemetry.dynamic_families()

  defp emitted_events, do: Invariants.scan_lib!(@lib_root)

  defp covered?(event) do
    event in @static_events or Enum.any?(@families, &List.starts_with?(event, &1))
  end

  # Matches the family prefix at the head of an event-name expression, so it hits
  # both the emit site (`..., :queue, suffix]`) and a doc reference to a concrete
  # member. Derived from the registry rather than restated, so it cannot drift.
  defp family_pattern(family) do
    body = family |> Enum.map(&":#{&1}") |> Enum.join("\\s*,\\s*")
    Regex.compile!("\\[" <> body <> "\\s*[,\\]]")
  end

  test "the lib tree was found, so the assertions below are not vacuous" do
    assert length(@sources) > 50,
           "found only #{length(@sources)} modules under #{@lib_root}; if the " <>
             "package layout moved, point this test at its new home rather " <>
             "than deleting it"

    assert length(@found_literals) >= 10,
           "found only #{length(@found_literals)} telemetry event literals under " <>
             "#{@lib_root}, which is fewer than this package is known to " <>
             "mention; the scan is broken, not the registry"

    assert File.exists?(@registry_source),
           "#{@registry_source} is missing, so excluding it from the scans " <>
             "would silently weaken every assertion below"
  end

  test "every event emitted from lib/ is classified in Raxol.Earn.Telemetry" do
    emitted = emitted_events()

    assert length(emitted) >= 5,
           "scan_lib!/1 found only #{length(emitted)} emitted events " <>
             "(#{inspect(emitted)}); this package emits at least 5 static " <>
             "names, so the scanner or the package layout changed"

    unclassified = Enum.reject(emitted, &covered?/1)

    assert unclassified == [], """
    These telemetry events are emitted from #{@lib_root} but are not classified
    in Raxol.Earn.Telemetry:

        #{inspect(unclassified, pretty: true)}

    Classify each one as :invariant (can only fire if this library is wrong),
    :peer (a misbehaving remote party caused it) or :operational (normal life --
    lifecycle, config, chain and network reality), with a comment saying why.
    Err toward :peer/:operational: a false invariant makes the suite flaky,
    which is worse than a missed one.
    """
  end

  test "every event literal mentioned in lib/ is classified or covered by a family" do
    unclassified = Enum.reject(@found_literals, &covered?/1)

    assert unclassified == [], """
    These telemetry event literals appear in #{@lib_root} -- in an emit site, an
    attribute binding or a moduledoc -- but are neither classified in
    Raxol.Earn.Telemetry nor covered by one of its dynamic: families:

        #{inspect(unclassified, pretty: true)}
    """
  end

  test "the registry claims no static event this package does not emit" do
    phantom = @static_events -- emitted_events()

    assert phantom == [], """
    Raxol.Earn.Telemetry classifies events that are emitted nowhere under
    #{@lib_root}: #{inspect(phantom, pretty: true)}. A stale entry reads as
    coverage this package does not have -- either the emit site moved out of
    lib/ or the entry should go.
    """
  end

  test "every dynamic: family has an emit site or reference in lib/" do
    contents = Enum.map(@sources, &File.read!/1)

    orphans =
      Enum.reject(@families, fn family ->
        pattern = family_pattern(family)
        Enum.any?(contents, &Regex.match?(pattern, &1))
      end)

    assert orphans == [], """
    These dynamic: families are declared in Raxol.Earn.Telemetry but no module
    under #{@lib_root} builds a name under them: #{inspect(orphans, pretty: true)}.
    A family nobody emits hides nothing and should go.
    """
  end

  test "every classification is one of the three known verdicts" do
    bogus =
      Telemetry.events()
      |> Enum.reject(fn {_event, class} -> class in [:invariant, :peer, :operational] end)

    assert bogus == [],
           "unknown classification(s) in Raxol.Earn.Telemetry: #{inspect(bogus)}"
  end

  test "invariant_events/0 is exactly the :invariant subset of events/0" do
    derived =
      Telemetry.events()
      |> Enum.filter(fn {_event, class} -> class == :invariant end)
      |> Enum.map(fn {event, _class} -> event end)
      |> Enum.sort()

    assert Telemetry.invariant_events() == derived
  end

  test "no dynamic: family is enforceable, because the sentinel cannot spell it" do
    # The sentinel attaches to exact names; a family whose final segment is built
    # at run time has no name to attach to. The macro rejects {family, :invariant}
    # at compile time -- this pins the resulting property from the outside.
    for family <- @families do
      refute Telemetry.classification(family) == :invariant,
             "#{inspect(family)} is a dynamic family and cannot be an invariant"
    end
  end
end
