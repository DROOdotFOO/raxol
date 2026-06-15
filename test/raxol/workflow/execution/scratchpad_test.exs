defmodule Raxol.Workflow.Execution.ScratchpadTest do
  use ExUnit.Case, async: true

  alias Raxol.Workflow.Execution.Scratchpad

  setup do
    on_exit(fn -> Scratchpad.clear() end)
    :ok
  end

  describe "init/2" do
    test "creates a scratchpad with empty queue when no resume values" do
      assert :ok = Scratchpad.init("run-1")
      assert %{run_id: "run-1"} = Scratchpad.get()
      assert :empty = Scratchpad.take_resume()
    end

    test "seeds the queue with a list of resume values, FIFO" do
      Scratchpad.init("run-1", [:first, :second, :third])

      assert {:ok, :first} = Scratchpad.take_resume()
      assert {:ok, :second} = Scratchpad.take_resume()
      assert {:ok, :third} = Scratchpad.take_resume()
      assert :empty = Scratchpad.take_resume()
    end

    test "subsequent init overwrites prior scratchpad" do
      Scratchpad.init("run-1", [:first])
      Scratchpad.init("run-2", [:second])

      assert {:ok, :second} = Scratchpad.take_resume()
    end
  end

  describe "take_resume/0" do
    test "returns :empty when no scratchpad exists" do
      assert :empty = Scratchpad.take_resume()
    end

    test "draining all values then taking again returns :empty" do
      Scratchpad.init("run", [:only])
      assert {:ok, :only} = Scratchpad.take_resume()
      assert :empty = Scratchpad.take_resume()
    end
  end

  describe "clear/0" do
    test "removes the scratchpad" do
      Scratchpad.init("run", [:x])
      Scratchpad.clear()
      assert Scratchpad.get() == nil
      assert :empty = Scratchpad.take_resume()
    end

    test "is idempotent" do
      assert :ok = Scratchpad.clear()
      assert :ok = Scratchpad.clear()
    end
  end
end
