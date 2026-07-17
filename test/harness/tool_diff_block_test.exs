defmodule Raxol.Harness.ToolDiffBlockTest do
  @moduledoc """
  Pins the diff-block route: a tool_result carrying a before/after file
  image (the shape `Raxol.Agent.Contract.pump/3` produces for
  `write_file`/`edit_file`) resolves to a `:diff` block through the live
  event path (EventBoundary -> Projection), NOT a generic tool row — so the
  surface renders a foldable ± diff, the "visualisation of diffs" ask.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.EventBoundary
  alias Raxol.Harness.Projection

  # A Contract.Event-shaped map (atom top-level fields, atom payload keys),
  # exactly what the live SessionLane delivers and the driver normalizes.
  defp event(id, type, payload) do
    %{
      id: id,
      turn_id: "t1",
      ts: id,
      family: :loop,
      type: type,
      tier: :durable,
      scope: :session,
      provenance: %{source: :primary, trust: :trusted},
      payload: payload
    }
  end

  defp normalize_all(events) do
    Enum.map(events, fn e ->
      {:ok, norm} = EventBoundary.normalize(e)
      norm
    end)
  end

  defp blocks(events) do
    events
    |> normalize_all()
    |> Projection.project()
    |> Projection.identity()
    |> elem(0)
  end

  test "an edit_file diff tool_result becomes a standalone :diff block with old/new content" do
    events = [
      event(0, :turn_started, %{prompt: "bump it"}),
      event(1, :item_completed, %{
        item_id: "i1",
        item_type: :tool_use,
        name: "edit_file"
      }),
      event(2, :item_completed, %{
        item_id: "i2",
        item_type: :tool_result,
        name: "edit_file",
        diff: true,
        path: "code.ex",
        old: "value = 1\n",
        new: "value = 2\n",
        language: "elixir"
      }),
      event(3, :turn_completed, %{final: true, usage: %{}})
    ]

    blocks = blocks(events)
    diff_block = Enum.find(blocks, &(&1.kind == :diff))

    assert diff_block,
           "expected a :diff block, got kinds: #{inspect(Enum.map(blocks, & &1.kind))}"

    # A :diff block's content is the extracted %{path, old, new, language}
    # (Block.extract_content(:diff, events)) — the ± viewer's props.
    assert %{path: "code.ex", old: old, new: new, language: "elixir"} =
             diff_block.content

    assert old =~ "value = 1"
    assert new =~ "value = 2"
  end

  test "a NON-diff tool_result still merges into a :tool_call block (no regression)" do
    events = [
      event(0, :turn_started, %{prompt: "read it"}),
      event(1, :item_completed, %{
        item_id: "i1",
        item_type: :tool_use,
        name: "read_file"
      }),
      event(2, :item_completed, %{
        item_id: "i2",
        item_type: :tool_result,
        name: "read_file",
        result: %{content: "hello"}
      }),
      event(3, :turn_completed, %{final: true, usage: %{}})
    ]

    kinds = blocks(events) |> Enum.map(& &1.kind)
    assert :tool_call in kinds
    refute :diff in kinds
  end
end
