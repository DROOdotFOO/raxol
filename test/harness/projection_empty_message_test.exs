defmodule Raxol.Harness.ProjectionEmptyMessageTest do
  @moduledoc """
  An empty assistant `:message` item builds NO block — pinned at the
  projection (defense in depth behind `Raxol.Agent.Contract.pump/3`'s
  producer-side suppression, for journals recorded before that fix and
  for producers that lack it).

  An empty message is not information: nothing was said, so there is
  nothing to render — building it seals a blank `❮` line into the
  transcript (the live defect: a provider round carrying tool_calls
  ships its assistant message with content `""`/whitespace next to the
  real calls).

  The suppression is deliberately NARROW — assistant messages only:

    * an empty USER echo still builds (a producer bug worth seeing);
    * an empty tool_result still builds ("the tool returned nothing" IS
      a real receipt);
    * suppression is disclosed via an `:empty_message_suppressed`
      diagnostic, never fully silent.
  """
  use ExUnit.Case, async: true

  alias Raxol.Harness.Projection

  defp ev(id, type, payload, turn_id \\ "t1") do
    %{
      id: id,
      turn_id: turn_id,
      ts: 100 + id,
      family: :loop,
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  defp message(id, item_id, content, extra \\ %{}) do
    [
      ev(id, :item_started, %{"item_id" => item_id, "item_type" => "message"}),
      ev(
        id + 1,
        :item_completed,
        Map.merge(
          %{
            "item_id" => item_id,
            "item_type" => "message",
            "content" => content
          },
          extra
        )
      )
    ]
  end

  defp tool_use(id, item_id, name) do
    [
      ev(id, :item_started, %{"item_id" => item_id, "item_type" => "tool_use"}),
      ev(id + 1, :item_completed, %{
        "item_id" => item_id,
        "item_type" => "tool_use",
        "name" => name,
        "arguments" => %{}
      })
    ]
  end

  defp tool_result(id, item_id, name, content) do
    [
      ev(id, :item_started, %{
        "item_id" => item_id,
        "item_type" => "tool_result"
      }),
      ev(id + 1, :item_completed, %{
        "item_id" => item_id,
        "item_type" => "tool_result",
        "name" => name,
        "content" => content
      })
    ]
  end

  defp project(events), do: Projection.project(events)

  defp kinds(events), do: project(events).blocks |> Enum.map(& &1.kind)

  defp diag_reasons(events),
    do: project(events).diagnostics |> Enum.map(& &1.reason)

  test "an empty assistant message item builds no block" do
    events =
      [ev(1, :turn_started, %{})] ++
        message(2, "i1", "") ++
        [ev(4, :turn_completed, %{})]

    assert kinds(events) == []
    assert :empty_message_suppressed in diag_reasons(events)
  end

  test "a whitespace-only assistant message item builds no block" do
    events =
      [ev(1, :turn_started, %{})] ++
        message(2, "i1", "\n\n \t") ++
        [ev(4, :turn_completed, %{})]

    assert kinds(events) == []
    assert :empty_message_suppressed in diag_reasons(events)
  end

  test "the live shape: empty pre-tool message between reasoning and the tool round" do
    # The reported transcript: ⁖ thinking, then a blank ❮, then ⚙ read_file.
    # The blank ❮ must not build; thinking and the tool round are untouched.
    events =
      [
        ev(1, :turn_started, %{}),
        ev(2, :item_started, %{"item_id" => "i1", "item_type" => "reasoning"}),
        ev(3, :item_completed, %{
          "item_id" => "i1",
          "item_type" => "reasoning",
          "content" => "let me look\nat mix.exs"
        })
      ] ++
        message(4, "i2", "\n\n") ++
        tool_use(6, "i3", "read_file") ++
        tool_result(8, "i4", "read_file", "defmodule...") ++
        [ev(10, :turn_completed, %{})]

    assert kinds(events) == [:reasoning, :tool_call]
    assert :empty_message_suppressed in diag_reasons(events)
  end

  test "suppression restores the tool_use/tool_result merge adjacency" do
    # tool_use / empty message / tool_result: with the empty item dropped
    # BEFORE the lookahead walk, the pair merges back into the ONE
    # :tool_call block it would have been had the item never existed.
    events =
      [ev(1, :turn_started, %{})] ++
        tool_use(2, "i1", "list_dir") ++
        message(4, "i2", "") ++
        tool_result(6, "i3", "list_dir", "mix.exs") ++
        [ev(8, :turn_completed, %{})]

    assert kinds(events) == [:tool_call]
  end

  test "a non-empty assistant message still builds" do
    events =
      [ev(1, :turn_started, %{})] ++
        message(2, "i1", "hello") ++
        [ev(4, :turn_completed, %{})]

    assert kinds(events) == [:message]
    refute :empty_message_suppressed in diag_reasons(events)
  end

  test "an empty USER message is NOT suppressed (a producer bug worth seeing)" do
    events =
      [ev(1, :turn_started, %{})] ++
        message(2, "i1", "", %{"role" => "user"}) ++
        [ev(4, :turn_completed, %{})]

    assert kinds(events) == [:message]
    refute :empty_message_suppressed in diag_reasons(events)
  end

  test "an empty tool_result is NOT suppressed (an empty receipt is a receipt)" do
    events =
      [ev(1, :turn_started, %{})] ++
        tool_result(2, "i1", "run_tests", "") ++
        [ev(4, :turn_completed, %{})]

    assert kinds(events) == [:tool_call]
    refute :empty_message_suppressed in diag_reasons(events)
  end

  test "empty reasoning is NOT suppressed by this guard" do
    # The producer never seals blank reasoning ("empty thinking → no ∴
    # block"), but a journal that carries one anyway renders it — the
    # narrow guard here is for assistant MESSAGES only.
    events =
      [
        ev(1, :turn_started, %{}),
        ev(2, :item_started, %{"item_id" => "i1", "item_type" => "reasoning"}),
        ev(3, :item_completed, %{
          "item_id" => "i1",
          "item_type" => "reasoning",
          "content" => ""
        }),
        ev(4, :turn_completed, %{})
      ]

    assert kinds(events) == [:reasoning]
    refute :empty_message_suppressed in diag_reasons(events)
  end
end
