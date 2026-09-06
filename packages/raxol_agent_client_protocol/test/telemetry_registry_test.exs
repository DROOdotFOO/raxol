defmodule Raxol.AgentClientProtocol.TelemetryRegistryTest do
  @moduledoc """
  Keeps `Raxol.AgentClientProtocol.Telemetry.events/0` in lockstep with the
  events `lib/` actually emits, by parsing `lib/` rather than trusting a hand
  list.

  This is the load-bearing half of the invariant mechanism: without it, a new
  telemetry event can be added and silently never classified, and the sentinel
  simply never arms for it. With it, adding an event forces the author to state
  whether it means "we are wrong", "the peer is wrong", or "this is normal".

  Source-parsing a registry is an established pattern here:
  `test/formatter_delegation_test.exs` (repo root) parses the CI matrix out of
  `.github/workflows/ci-unified.yml`, and
  `packages/raxol_agent/test/raxol/agent/acp_stream_adapter_coverage_test.exs`
  parses the ACP schema's `from_json/1` clauses. Like those, this test carries a
  vacuity guard so a moved/renamed source tree fails loudly instead of passing
  on an empty scan.
  """
  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Telemetry

  # Floors for the vacuity guard. Deliberately far below today's counts (43
  # source files, 17 events): they exist to catch "scanned nothing", not to be
  # a second, drift-prone inventory.
  @min_files 20
  @min_events 12

  describe "registry completeness" do
    setup do
      {files, events} = scan_lib()
      {:ok, files: files, events: events}
    end

    test "the scan actually found source and events (vacuity guard)", ctx do
      assert length(ctx.files) >= @min_files,
             "scanned only #{length(ctx.files)} file(s) under #{lib_root()}; " <>
               "the source tree moved and this test would otherwise pass vacuously"

      assert map_size(ctx.events) >= @min_events,
             "found only #{map_size(ctx.events)} telemetry event literal(s) in lib/; " <>
               "emission moved behind an indirection this parser cannot see"
    end

    test "every event emitted in lib/ is classified", ctx do
      unclassified =
        ctx.events
        |> Enum.reject(fn {event, _sites} -> Map.has_key?(Telemetry.events(), event) end)
        |> Enum.sort()

      assert unclassified == [],
             """
             Telemetry events emitted from lib/ but missing from
             Raxol.AgentClientProtocol.Telemetry.events/0:

             #{Enum.map_join(unclassified, "\n", fn {event, sites} -> "  * #{inspect(event)} at #{Enum.join(sites, ", ")}" end)}

             Classify each one as :invariant, :peer, or :operational (see that
             module's moduledoc for the criterion) with a one-line comment
             saying why.
             """
    end

    test "the registry claims no event lib/ does not emit", ctx do
      phantom = Enum.reject(Map.keys(Telemetry.events()), &Map.has_key?(ctx.events, &1))

      assert phantom == [],
             """
             Registered in Raxol.AgentClientProtocol.Telemetry.events/0 but not
             emitted anywhere in lib/: #{inspect(Enum.sort(phantom))}

             Remove the row, or restore the emit site it was written for.
             """
    end

    test "invariant_events/0 is exactly the :invariant subset of events/0" do
      expected =
        Telemetry.events()
        |> Enum.filter(fn {_event, class} -> class == :invariant end)
        |> Enum.map(fn {event, _class} -> event end)
        |> Enum.sort()

      assert Telemetry.invariant_events() == expected
    end

    test "every class is one of the three declared values" do
      bad =
        Enum.reject(Telemetry.events(), fn {_e, c} -> c in [:invariant, :peer, :operational] end)

      assert bad == []
    end
  end

  describe "measured classifications" do
    test "the events that would have caught shipped bugs are invariants" do
      # Pinned because these two are the whole reason the mechanism exists:
      # zero_updates_turn is the event a shipped bug fired unobserved, and
      # dup_reply is our own reply-obligation bookkeeping. Weakening either to
      # :peer/:operational to make a suite green must be a deliberate,
      # test-breaking act.
      assert Telemetry.classify([:raxol, :acp, :zero_updates_turn]) == :invariant
      assert Telemetry.classify([:raxol, :acp, :dup_reply]) == :invariant
    end

    test "peer-caused framing and protocol errors are not invariants" do
      for event <- [
            [:raxol, :acp, :parse_error],
            [:raxol, :acp, :malformed_response],
            [:raxol, :acp, :unknown_notification],
            [:raxol, :acp, :invalid_request_frame],
            [:raxol, :acp, :duplicate_inflight_id],
            [:raxol, :acp, :late_response]
          ] do
        assert Telemetry.classify(event) == :peer, "#{inspect(event)} must stay :peer"
      end
    end

    test "an unregistered event classifies as nil" do
      assert Telemetry.classify([:raxol, :acp, :no_such_event]) == nil
    end
  end

  # -- Scanner ----------------------------------------------------------------

  defp lib_root, do: Path.join(File.cwd!(), "lib")

  # Parse each source file and walk its AST for `[:raxol, ...]` list literals of
  # atoms. AST rather than regex on purpose: a `@doc` or comment that mentions
  # an event name is prose, not an emit site, and must not satisfy the registry.
  @spec scan_lib() :: {[String.t()], %{[atom()] => [String.t()]}}
  defp scan_lib do
    files = lib_root() |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort()

    events =
      Enum.reduce(files, %{}, fn file, acc ->
        rel = Path.relative_to(file, File.cwd!())

        file
        |> File.read!()
        |> Code.string_to_quoted!(file: file, columns: false)
        |> collect_events()
        |> Enum.reduce(acc, fn event, inner ->
          Map.update(inner, event, [rel], &Enum.uniq([rel | &1]))
        end)
      end)

    {files, events}
  end

  @spec collect_events(Macro.t()) :: [[atom()]]
  defp collect_events(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        if event_literal?(node), do: {node, [node | acc]}, else: {node, acc}
      end)

    Enum.uniq(found)
  end

  # A telemetry event literal: a list of two or more plain atoms starting with
  # `:raxol`. Anything with a non-atom element (a variable, an interpolation) is
  # not a literal event name -- there are none today, and the vacuity guard is
  # the backstop if emission ever moves behind such an indirection.
  @spec event_literal?(Macro.t()) :: boolean()
  defp event_literal?([:raxol | rest] = node) when rest != [],
    do: Enum.all?(node, &is_atom/1)

  defp event_literal?(_node), do: false
end
