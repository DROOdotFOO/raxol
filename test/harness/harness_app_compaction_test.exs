defmodule Raxol.Harness.HarnessAppCompactionTest do
  @moduledoc """
  `HarnessApp.Model.compact_sealed_turns/1` — the live-session memory
  bound ported from the retired Surface engine.

  Two pins:

    * **Contract** — on a revealed model, compaction drops exactly the
      retired-turn event prefix, reprojects the survivors identically to
      the old projection minus the dropped leading sealed blocks, leaves
      the sealed transcript untouched, and is idempotent. (Direct call:
      folding `{:batch, {:event, _}}` compacts inline at every
      `turn_completed`, so a "no compaction" twin cannot be produced by
      any public fold — the contract is pinned on the function itself.)
    * **Veto** — a surviving event citing a dropped id in `payload.refs`
      keeps the whole prefix.
  """
  use ExUnit.Case, async: true

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.HarnessApp
  alias Raxol.Harness.HarnessApp.Model

  @long_folds Path.join([
                __DIR__,
                "..",
                "fixtures",
                "harness",
                "sessions",
                "long-folds.jsonl"
              ])

  defp fixture_events(path) do
    {:ok, session} = Fixture.load(path)
    Enum.map(session.envelopes, & &1.body)
  end

  defp turn1_prefix(events) do
    Enum.take_while(events, &(&1.type != :turn_completed)) ++
      [Enum.find(events, &(&1.type == :turn_completed))]
  end

  test "compaction drops the retired prefix and preserves the sealed transcript" do
    events = fixture_events(@long_folds)

    # Two full turns revealed: turn 1 is retired (turn 2 is the newest
    # bracketed turn and is kept).
    two_turns = turn1_prefix(events) ++ turn1_prefix(Enum.drop(events, 6))

    snapshot =
      Model.build(events: two_turns, width: 80, rows: 24)
      |> Model.reveal_all()

    compacted = Model.compact_sealed_turns(snapshot)

    dropped_events = length(snapshot.events) - length(compacted.events)
    dropped_blocks =
      length(snapshot.projection.blocks) - length(compacted.projection.blocks)

    # Engaged: turn 1's events and its leading sealed blocks are gone.
    assert dropped_events > 0
    assert dropped_blocks > 0

    # The surviving event suffix is exactly the uncovered tail.
    assert compacted.events == Enum.drop(snapshot.events, dropped_events)
    assert compacted.revealed == snapshot.revealed - dropped_events
    assert compacted.revealed == length(compacted.events)

    # The projection is the old one minus the dropped leading blocks.
    assert compacted.projection.blocks ==
             Enum.drop(snapshot.projection.blocks, dropped_blocks)

    assert compacted.projection.tail == snapshot.projection.tail
    assert compacted.painted_count == snapshot.painted_count - dropped_blocks

    # Sealed history is append-only: compaction never rewrites it.
    assert compacted.transcript_records == snapshot.transcript_records

    # Fold overrides / focus shift with the blocks, never below zero.
    assert compacted.focused_index in [nil] or compacted.focused_index >= 0

    # Idempotent: only the newest bracketed turn survives, so a second
    # pass is a no-op.
    assert Model.compact_sealed_turns(compacted) == compacted
  end

  test "folding a 6-turn session compacts down to the live tail" do
    events = fixture_events(@long_folds)

    compacted =
      Enum.reduce(events, Model.build(width: 80, rows: 24), fn event, model ->
        {model, _cmds} = HarnessApp.update({:batch, [{:event, event}]}, model)
        model
      end)

    # Every turn_completed compacted inline: of 36 events only the live
    # tail survives, all of it revealed, with the sealed history intact.
    assert length(compacted.events) < length(events)
    assert compacted.revealed == length(compacted.events)
    assert compacted.transcript_records != []
  end

  test "a surviving event citing a dropped id vetoes compaction" do
    cited = [
      %{id: 1, turn_id: "t1", family: :loop, type: :turn_started, payload: %{}},
      %{id: 2, turn_id: "t1", family: :loop, type: :item_started,
        payload: %{"item_id" => "i1", "item_type" => "reasoning"}},
      %{id: 3, turn_id: "t1", family: :loop, type: :item_completed,
        payload: %{"item_id" => "i1", "item_type" => "reasoning"}},
      %{id: 4, turn_id: "t1", family: :loop, type: :turn_completed, payload: %{}},
      %{id: 5, turn_id: "t2", family: :loop, type: :turn_started, payload: %{}},
      %{id: 6, turn_id: "t2", family: :loop, type: :item_started,
        payload: %{"item_id" => "i2", "item_type" => "reasoning"}},
      # The turn-2 completion CITES turn-1 event 1 — an evidence ref that
      # must never dangle into a compacted region.
      %{id: 7, turn_id: "t2", family: :loop, type: :item_completed,
        payload: %{"item_id" => "i2", "item_type" => "reasoning", "refs" => [1]}},
      %{id: 8, turn_id: "t2", family: :loop, type: :turn_completed, payload: %{}}
    ]

    vetoed =
      Model.build(events: cited, width: 80, rows: 24)
      |> Model.reveal_all()
      |> Model.compact_sealed_turns()

    assert length(vetoed.events) == length(cited)

    # Sanity: the same stream without the citation compacts.
    uncited =
      cited
      |> Enum.map(fn
        %{id: 7} = e -> %{e | payload: Map.delete(e.payload, "refs")}
        e -> e
      end)

    compacted =
      Model.build(events: uncited, width: 80, rows: 24)
      |> Model.reveal_all()
      |> Model.compact_sealed_turns()

    assert length(compacted.events) < length(uncited)
  end
end
