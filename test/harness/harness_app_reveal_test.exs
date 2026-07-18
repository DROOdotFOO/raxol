defmodule Raxol.Harness.HarnessAppRevealTest do
  @moduledoc """
  U4 reveal/seal core: replaying a fixture through `HarnessApp.Model` seals
  exactly the projection's blocks in order, sealed records are logically
  immutable (law 1), reveal carries no clock (event-clocked motion, law 2),
  and the prompt echo seals before its answer (echo-on-accept ordering).
  """
  use ExUnit.Case, async: true

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.HarnessApp.Model

  defp load(name) do
    {:ok, session} =
      Fixture.load("test/fixtures/harness/sessions/#{name}.jsonl")

    session
  end

  # oldest-first sealed blocks
  defp sealed_blocks(model) do
    model.transcript_records
    |> Enum.reverse()
    |> Enum.flat_map(fn
      {:block, block, _prominence} -> [block]
      _ -> []
    end)
  end

  defp reveal_until(model, pred) do
    cond do
      pred.(model) -> model
      Model.done?(model) -> model
      true -> model |> Model.advance() |> reveal_until(pred)
    end
  end

  test "revealing a fixture seals exactly the projection's blocks, in journal order" do
    model =
      "multi-tool-turn"
      |> load()
      |> then(&Model.build(events: &1))
      |> Model.reveal_all()

    assert Model.done?(model)
    sealed = sealed_blocks(model)
    assert sealed != []

    # identity = event_refs; every projection block was sealed, in order
    assert Enum.map(sealed, & &1.event_refs) ==
             Enum.map(model.projection.blocks, & &1.event_refs)
  end

  test "law 1: an event that does not touch a block leaves every sealed record byte-identical" do
    model =
      "multi-tool-turn"
      |> load()
      |> then(&Model.build(events: &1))
      |> Model.reveal_all()

    records = model.transcript_records
    assert records != []

    # tick / notice / stall verdict touch no block — the transcript is frozen
    touched =
      model
      |> Model.tick(999_999)
      |> Model.put_lane_notice("reconnecting")
      |> Model.put_stall_verdict(%{class: :looping, evidence: "x"})
      |> Model.put_debug_highlight(:status)

    assert touched.transcript_records == records
  end

  test "law 1: further reveals never rewrite an already-sealed record" do
    model = "long-folds" |> load() |> then(&Model.build(events: &1))
    partial = reveal_until(model, fn m -> length(sealed_blocks(m)) >= 2 end)
    before = partial.transcript_records
    assert length(before) >= 2

    full = Model.reveal_all(partial)
    # records are newest-first, so the already-sealed prefix is the suffix
    assert Enum.take(full.transcript_records, -length(before)) == before
  end

  test "law 2: reveal carries no clock — the transcript is identical with or without `now`" do
    session = load("multi-tool-turn")
    a = Model.build(events: session) |> Model.reveal_all(nil)
    b = Model.build(events: session) |> Model.reveal_all(123_456)
    assert a.transcript_records == b.transcript_records
  end

  test "echo-on-accept ordering: submit_accepted seals the prompt echo before its answer" do
    model = "simple-chat" |> load() |> then(&Model.build(events: &1))

    accepted =
      %{model | pending_submit: %{text: "explain the plan"}}
      |> Model.submit_accepted()

    assert accepted.pending_submit == nil
    assert [{:echo, "explain the plan"} | _] = accepted.transcript_records

    revealed = Model.reveal_all(accepted)
    oldest_first = Enum.reverse(revealed.transcript_records)
    echo_i = Enum.find_index(oldest_first, &match?({:echo, _}, &1))
    block_i = Enum.find_index(oldest_first, &match?({:block, _, _}, &1))

    assert echo_i != nil
    if block_i, do: assert(echo_i < block_i)
  end

  test "submit_accepted is a no-op without a pending submit (an externally-initiated turn)" do
    model = "simple-chat" |> load() |> then(&Model.build(events: &1))
    assert Model.submit_accepted(model) == model
  end
end
