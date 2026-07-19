defmodule Raxol.Harness.ProjectionDiffDedupTest do
  @moduledoc """
  V's no-raw-output-next-to-the-nice-diff ruling, pinned at the
  projection: a tool call whose referent a ± diff already renders builds
  NO separate raw-args block.

    * a `tool_use` whose `tool_result` carries the diff marker builds
      ONLY the `:diff` block (the pair used to build `⊘ tool_use` + `±`);
    * a RESULTLESS `tool_call` covered by a same-turn diff-carrying
      `:approval` block is suppressed (the live `⊘ edit_file args…` dup);
    * ordinary tools (non-diff results) still merge into one `:tool_call`
      block, and a resultless call with NO covering approval stays.
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

  defp tool_use(id, item_id, name, args) do
    [
      ev(id, :item_started, %{"item_id" => item_id, "item_type" => "tool_use"}),
      ev(id + 1, :item_completed, %{
        "item_id" => item_id,
        "item_type" => "tool_use",
        "name" => name,
        "arguments" => args
      })
    ]
  end

  defp tool_result(id, item_id, name, content, extra \\ %{}) do
    [
      ev(id, :item_started, %{
        "item_id" => item_id,
        "item_type" => "tool_result"
      }),
      ev(
        id + 1,
        :item_completed,
        Map.merge(
          %{
            "item_id" => item_id,
            "item_type" => "tool_result",
            "name" => name,
            "content" => content
          },
          extra
        )
      )
    ]
  end

  defp kinds(events),
    do: Projection.project(events).blocks |> Enum.map(& &1.kind)

  test "a diff-marked result builds ONLY the :diff block — no ⊘ tool_use dup" do
    events =
      [ev(1, :turn_started, %{})] ++
        tool_use(2, "i1", "edit_file", %{"path" => "mix.exs"}) ++
        tool_result(4, "i2", "edit_file", "ok", %{
          "diff" => true,
          "path" => "mix.exs",
          "old" => "a\nOLD\n",
          "new" => "a\nNEW\n",
          "language" => "elixir"
        }) ++
        [ev(6, :turn_completed, %{})]

    assert kinds(events) == [:diff]
  end

  test "a resultless tool_call covered by a diff-carrying approval is suppressed" do
    events =
      [ev(1, :turn_started, %{})] ++
        tool_use(2, "i1", "edit_file", %{"path" => "mix.exs"}) ++
        [
          ev(4, :approval_requested, %{
            "request_id" => "r1",
            "tool_name" => "edit_file",
            "action" => "edit_file",
            "path" => "mix.exs",
            "old" => "a\nOLD\n",
            "new" => "a\nNEW\n",
            "diff" => true,
            "options" => [
              %{"option_id" => "a", "name" => "Allow", "kind" => "allow_once"}
            ]
          })
        ]

    assert kinds(events) == [:approval]
  end

  test "an ordinary tool round-trip still merges into ONE :tool_call block" do
    events =
      [ev(1, :turn_started, %{})] ++
        tool_use(2, "i1", "list_dir", %{"path" => "."}) ++
        tool_result(4, "i2", "list_dir", "mix.exs\nlib/") ++
        [ev(6, :turn_completed, %{})]

    assert kinds(events) == [:tool_call]
  end

  test "a resultless tool_call with NO covering approval stays (honest pending)" do
    events =
      [ev(1, :turn_started, %{})] ++
        tool_use(2, "i1", "run_tests", %{})

    assert kinds(events) == [:tool_call]
  end

  test "a bash approval (no diff image) does NOT suppress its tool_call" do
    events =
      [ev(1, :turn_started, %{})] ++
        tool_use(2, "i1", "bash", %{"command" => "rm -rf tmp"}) ++
        [
          ev(4, :approval_requested, %{
            "request_id" => "r2",
            "tool_name" => "bash",
            "action" => "bash",
            "options" => [
              %{"option_id" => "a", "name" => "Allow", "kind" => "allow_once"}
            ]
          })
        ]

    kinds = kinds(events)
    assert :approval in kinds
    assert :tool_call in kinds
  end
end
