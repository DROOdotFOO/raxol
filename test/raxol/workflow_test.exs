defmodule Raxol.WorkflowTest do
  use ExUnit.Case, async: true

  alias Raxol.Workflow
  alias Raxol.Workflow.Execution.Scratchpad

  setup do
    on_exit(fn -> Scratchpad.clear() end)
    :ok
  end

  describe "interrupt/1" do
    test "throws {:__workflow_interrupt__, value} when no resume value is queued" do
      assert catch_throw(Workflow.interrupt(:awaiting_approval)) ==
               {:__workflow_interrupt__, :awaiting_approval}
    end

    test "returns the head of the resume queue without throwing" do
      Scratchpad.init("run", [:approved])

      assert Workflow.interrupt(:awaiting_approval) == :approved
    end

    test "consumes one value per call" do
      Scratchpad.init("run", [:first, :second])

      assert Workflow.interrupt(:_) == :first
      assert Workflow.interrupt(:_) == :second

      assert catch_throw(Workflow.interrupt(:_)) ==
               {:__workflow_interrupt__, :_}
    end
  end
end
