defmodule Raxol.Agent.DoneGateHonestyBoundTest do
  # The compile-time link PR #619's review (DROOdotFOO, 2026-07-17) flagged as
  # missing — the one LOW follow-up on an otherwise-CLEAN merge verdict.
  #
  # The transcript renderer `Raxol.Harness.Projection.BlockBuilder` (main
  # `raxol`) leaves same-turn `stale_evidence` / `mutation_echo` refs UNMARKED
  # (its moduledoc "Knowingly unmarked: stale and mutation-echo" section). That
  # is safe ONLY because of a bound whose two halves both live in `raxol_agent`:
  #
  #   1. the honest producer (`Contract.gated_done_payload/4`) attaches a `refs`
  #      key to `turn_completed{final: true}` ONLY when `DoneGate.gate/3`
  #      ACCEPTS; every rejection path drops the offered refs on the floor; and
  #   2. on a v0 producer journal (no structural effect classification)
  #      `DoneGate` is fully fail-closed — every tool call is a mutation and
  #      every result is some call's echo, so the gate accepts nothing.
  #
  # Together: today's honest wire never carries `refs` at all, so the renderer's
  # unmarked-stale/echo path is unreachable on honest output. Because the frozen
  # package graph runs `raxol_agent -> raxol` and NEVER the reverse, the renderer
  # cannot compile-reference the gate, and the gate has no idea the renderer is
  # leaning on it. A future fail-open gate change (filling the
  # `classified_effect_free?/1` seam, or attaching refs on a non-accept verdict)
  # would silently defeat the renderer's assumption and let laundered
  # false-clean evidence render as ordinary verification.
  #
  # This test IS that missing link. `raxol_agent`'s test suite is the ONLY tree
  # where both `Raxol.Agent.{Contract, DoneGate}` and `Raxol.Harness.Projection`
  # are loadable together (raxol_agent depends on main raxol), so pinning the
  # bound end-to-end must live here. If either half of the bound is ever broken,
  # a pin below goes RED instead of the break being silent. See
  # `Raxol.Harness.Projection.BlockBuilder`'s "Bound on the residual" moduledoc,
  # which cites this file.
  #
  # NOTE on the in-flight tri-state marker (#631, another #619 residual): that
  # PR makes the producer stamp `evidence: :accepted | :rejected | :absent` on
  # the wire but keeps `refs` refs-only-on-accept, so Claim A stays true; and the
  # current renderer keys the completion row off `refs` presence, so Claim B
  # stays `:none` until the T19 renderer consciously wires the enum — at which
  # point Claim B is exactly the conscious-decision guard this pin exists to be.

  # async: false — SessionStreamer is a named singleton (mirrors
  # Raxol.Agent.Red.U21RealProducerRegressionTest).
  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Harness.Projection

  setup do
    start_supervised!({SessionStreamer, []})
    :ok
  end

  # The round-3 failure scenario, produced for real by the frozen v0 producer:
  # run tests (pass), THEN edit code, then close the turn. The pre-edit test run
  # is stale (predates the fs_write mutation) and fs_write's own result is that
  # mutation's echo — neither is admissible evidence, so the fail-closed gate
  # rejects every candidate offset.
  #
  # Journal (all durable, one event per item): 1 turn_started,
  # 2 tool_use(run_tests), 3 tool_result(run_tests), 4 tool_use(fs_write),
  # 5 tool_result(fs_write), 6 message, 7 turn_completed{final: true}.
  defp honest_journal do
    session_id = "u21-honesty-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    stream = [
      {:tool_use, %{name: "run_tests", id: "call-1", arguments: %{}}},
      {:tool_result,
       %{name: "run_tests", result: "tests: 12 passed, 0 failed"}},
      {:tool_use,
       %{name: "fs_write", id: "call-2", arguments: %{path: "lib/a.ex"}}},
      {:tool_result, %{name: "fs_write", result: "wrote 42 bytes"}},
      {:done, %{content: "All fixed.", usage: %{}}}
    ]

    {:ok, _} = Contract.pump(session_id, stream, prompt: "fix the bug")

    journal = drain_events(session_id)
    [%Event{turn_id: turn_id} | _] = journal
    {journal, turn_id}
  end

  defp completion(journal) do
    journal
    |> Projection.project()
    |> Map.fetch!(:blocks)
    |> List.last()
    |> get_in([Access.key!(:content), Access.key!(:completion)])
  end

  describe "the honesty bound: fail-closed gate <-> unmarked renderer" do
    test "premise — the gate rejects every candidate offset on an honest v0 journal (nothing is admissible)" do
      # If this ever flips to an {:ok, _}, the gate has gone fail-OPEN and the
      # renderer's unmarked-stale/echo assumption is no longer covered by the
      # bound. This is the load-bearing half that lives in raxol_agent.
      {journal, turn} = honest_journal()

      for %Event{id: offset} <- journal do
        refute match?({:ok, _}, DoneGate.gate(journal, turn, [offset])),
               "offset #{offset} became admissible — the fail-closed gate opened; " <>
                 "the renderer's 'Knowingly unmarked' bound no longer holds"
      end
    end

    test "Claim A (producer) — the honest turn_completed carries final:true and NO refs key" do
      # refs-only-on-accept: because the gate rejects everything above, the real
      # producer drops the offered refs. The honest wire never carries them.
      {journal, _turn} = honest_journal()

      [done] = Enum.filter(journal, &(&1.type == :turn_completed))

      assert done.payload[:final] == true

      refute Map.has_key?(done.payload, :refs),
             "the honest wire carried a refs key on a fail-closed journal — " <>
               "the producer attached refs on a non-accept verdict"
    end

    test "Claim B (renderer bridge) — the honest journal renders the absence row, never laundered evidence" do
      # The cross-package link: feed the REAL honest journal through the
      # main-raxol renderer. With no refs on the wire it must resolve to the
      # explicit absence marker, never an (unmarked, laundered) evidence list.
      {journal, _turn} = honest_journal()

      assert completion(journal) == %{evidence: :none}
    end

    test "non-vacuity anchor — the renderer WOULD launder a stale ref; only the gate keeps it off the wire" do
      # Prove the bound is load-bearing, not vacuous: take the SAME journal but
      # inject refs pointing at the stale run_tests result (offset 3, which the
      # gate rejected as :stale_evidence above). The renderer renders it as
      # ordinary UNMARKED evidence — exactly the laundering the fail-closed gate
      # prevents by never letting the honest producer emit these refs.
      {journal, turn} = honest_journal()
      assert DoneGate.gate(journal, turn, [3]) == {:error, {:stale_evidence, 3}}

      tampered =
        Enum.map(journal, fn
          %Event{type: :turn_completed} = ev ->
            %{ev | payload: Map.put(ev.payload, :refs, [3])}

          ev ->
            ev
        end)

      laundered = completion(tampered)

      refute laundered == %{evidence: :none}
      assert %{evidence: [entry | _]} = laundered
      assert entry.ref == 3
      # The renderer does NOT mark it — no stale/echo signal exists display-side.
      refute Map.has_key?(entry, :stale)
      refute Map.has_key?(entry, :echo)
      refute Map.get(entry, :cross_turn, false)
    end
  end

  defp drain_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{tier: :durable} = event} ->
        drain_events(session_id, [event | acc])

      {:session_event, ^session_id, %Event{}} ->
        drain_events(session_id, acc)
    after
      100 -> Enum.reverse(acc)
    end
  end
end
