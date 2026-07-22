defmodule Raxol.Agent.Code.EventCodecTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.EventCodec
  alias Raxol.Agent.Contract
  alias Raxol.Harness.EventBoundary
  alias Raxol.Harness.Projection
  alias Raxol.UI.Components.Harness.Block

  defp ev(id, type, payload) do
    %Contract.Event{
      id: id,
      ts: id,
      turn_id: "t1",
      family: :loop,
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  defp normalize(event) do
    {:ok, norm} = EventBoundary.normalize(event)
    norm
  end

  # Persist-then-load: normalized event -> JSON -> back to projection shape.
  defp roundtrip(events) do
    events
    |> Enum.map(&normalize/1)
    |> Jason.encode!()
    |> Jason.decode!()
    |> EventCodec.decode_all()
  end

  test "decodes a persisted event back to projection shape" do
    [decoded] =
      roundtrip([ev(3, :item_completed, %{item_id: "i1", item_type: :message, content: "hi"})])

    assert decoded.id == 3
    assert decoded.type == :item_completed
    assert decoded.family == :loop
    assert decoded.tier == :durable
    assert decoded.turn_id == "t1"
    # Payload stays string-keyed (the projection wire shape).
    assert decoded.payload == %{"item_id" => "i1", "item_type" => "message", "content" => "hi"}
  end

  test "an unknown type string is left as a string (no atom minted from disk)" do
    decoded =
      EventCodec.decode(%{
        "id" => 1,
        "type" => "totally_unknown_type",
        "tier" => "durable",
        "family" => "loop",
        "payload" => %{}
      })

    assert decoded.type == "totally_unknown_type"
  end

  test "a record without an integer id is dropped" do
    assert EventCodec.decode(%{"type" => "error"}) == nil

    assert [%{id: 1}] =
             EventCodec.decode_all([
               %{"id" => 1, "type" => "error", "tier" => "durable", "payload" => %{}},
               %{"bad" => 1}
             ])
  end

  test "decoded events project into the same blocks as the live ones" do
    events = [
      ev(1, :turn_started, %{prompt: "hi"}),
      ev(2, :item_started, %{item_id: "i1", item_type: :message}),
      ev(3, :item_completed, %{item_id: "i1", item_type: :message, content: "hello world"}),
      ev(4, :turn_completed, %{final: true, usage: %{}})
    ]

    live = Enum.map(events, &normalize/1)
    reloaded = roundtrip(events)

    live_blocks = Projection.project(live).blocks
    reloaded_blocks = Projection.project(reloaded).blocks

    assert length(reloaded_blocks) == length(live_blocks)

    assert Enum.any?(reloaded_blocks, &(Block.search_text(&1) =~ "hello world"))
  end
end
