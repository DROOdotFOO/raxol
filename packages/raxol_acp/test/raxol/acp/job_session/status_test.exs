defmodule Raxol.ACP.JobSession.StatusTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.JobSession.Status

  describe "initial/0 + all/0" do
    test "initial is :open" do
      assert Status.initial() == :open
    end

    test "all/0 lists every status" do
      assert MapSet.equal?(
               MapSet.new(Status.all()),
               MapSet.new([:open, :budget_set, :funded, :submitted, :completed, :rejected, :expired])
             )
    end
  end

  describe "terminal?/1" do
    test ":completed, :rejected, :expired are terminal" do
      assert Status.terminal?(:completed)
      assert Status.terminal?(:rejected)
      assert Status.terminal?(:expired)
    end

    test "in-flight statuses are not terminal" do
      refute Status.terminal?(:open)
      refute Status.terminal?(:budget_set)
      refute Status.terminal?(:funded)
      refute Status.terminal?(:submitted)
    end
  end

  describe "validate/2" do
    test "happy path: open -> budget_set -> funded -> submitted -> completed" do
      assert :ok = Status.validate(:open, :budget_set)
      assert :ok = Status.validate(:budget_set, :funded)
      assert :ok = Status.validate(:funded, :submitted)
      assert :ok = Status.validate(:submitted, :completed)
    end

    test "alternative: submitted -> rejected" do
      assert :ok = Status.validate(:submitted, :rejected)
    end

    test "re-budget within :budget_set is allowed" do
      assert :ok = Status.validate(:budget_set, :budget_set)
    end

    test "expire is reachable from every non-terminal status" do
      for from <- [:open, :budget_set, :funded, :submitted] do
        assert :ok = Status.validate(from, :expired), "from #{from}"
      end
    end

    test "terminal statuses cannot transition further" do
      for from <- [:completed, :rejected, :expired],
          to <- Status.all() do
        assert {:error, {:invalid_transition, ^from, ^to}} = Status.validate(from, to)
      end
    end

    test "illegal jumps rejected" do
      assert {:error, _} = Status.validate(:open, :funded)
      assert {:error, _} = Status.validate(:open, :submitted)
      assert {:error, _} = Status.validate(:budget_set, :submitted)
      assert {:error, _} = Status.validate(:funded, :completed)
    end
  end

  describe "target_status/1" do
    test "maps actions to target statuses" do
      assert Status.target_status(:set_budget) == :budget_set
      assert Status.target_status(:set_budget_with_fund_request) == :budget_set
      assert Status.target_status(:set_budget_with_subscription) == :budget_set
      assert Status.target_status(:fund) == :funded
      assert Status.target_status(:submit) == :submitted
      assert Status.target_status(:complete) == :completed
      assert Status.target_status(:reject) == :rejected
      assert Status.target_status(:expire) == :expired
    end

    test "unknown action returns nil" do
      assert Status.target_status(:wat) == nil
    end
  end
end
