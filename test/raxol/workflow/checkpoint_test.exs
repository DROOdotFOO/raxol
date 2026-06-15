defmodule Raxol.Workflow.CheckpointTest do
  use ExUnit.Case, async: true

  alias Raxol.Workflow.Checkpoint

  describe "new/1" do
    test "builds a checkpoint from required fields with defaults" do
      cp =
        Checkpoint.new(
          thread_id: "thr-1",
          step: 0,
          state: %{count: 1}
        )

      assert cp.thread_id == "thr-1"
      assert cp.step == 0
      assert cp.state == %{count: 1}
      assert cp.metadata == %{}
      assert cp.parent_step == nil
      assert %DateTime{} = cp.created_at
    end

    test "respects optional fields" do
      time = ~U[2026-06-15 12:00:00Z]

      cp =
        Checkpoint.new(
          thread_id: "thr-1",
          step: 3,
          state: :anything,
          metadata: %{node_id: :work},
          parent_step: 2,
          created_at: time
        )

      assert cp.metadata == %{node_id: :work}
      assert cp.parent_step == 2
      assert cp.created_at == time
    end

    test "raises when required field is missing" do
      assert_raise KeyError, fn ->
        Checkpoint.new(step: 0, state: %{})
      end
    end
  end
end
