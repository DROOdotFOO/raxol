defmodule Raxol.Earn.JobSession.ToolsTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.JobSession.Tools

  describe "available/2 matrix from acp-node-v2 README" do
    test "provider × :open" do
      assert MapSet.equal?(
               MapSet.new(Tools.available(:provider, :open)),
               MapSet.new([:set_budget, :send_message, :wait])
             )
    end

    test "provider × :budget_set (can re-budget only)" do
      assert Tools.available(:provider, :budget_set) == [:set_budget]
    end

    test "provider × :funded" do
      assert Tools.available(:provider, :funded) == [:submit]
    end

    test "client × :open" do
      assert MapSet.equal?(
               MapSet.new(Tools.available(:client, :open)),
               MapSet.new([:send_message, :wait])
             )
    end

    test "client × :budget_set" do
      assert MapSet.equal?(
               MapSet.new(Tools.available(:client, :budget_set)),
               MapSet.new([:send_message, :fund, :wait])
             )
    end

    test "evaluator × :submitted" do
      assert MapSet.equal?(
               MapSet.new(Tools.available(:evaluator, :submitted)),
               MapSet.new([:complete, :reject])
             )
    end

    test "any role × terminal status -> no tools" do
      for role <- [:provider, :client, :evaluator],
          status <- [:completed, :rejected, :expired] do
        assert Tools.available(role, status) == []
      end
    end

    test "client cannot submit, complete, reject, set_budget" do
      refute Tools.allowed?(:client, :funded, :submit)
      refute Tools.allowed?(:client, :submitted, :complete)
      refute Tools.allowed?(:client, :submitted, :reject)
      refute Tools.allowed?(:client, :open, :set_budget)
    end

    test "provider cannot complete, reject, fund" do
      refute Tools.allowed?(:provider, :submitted, :complete)
      refute Tools.allowed?(:provider, :submitted, :reject)
      refute Tools.allowed?(:provider, :budget_set, :fund)
    end

    test "evaluator cannot act before :submitted" do
      for status <- [:open, :budget_set, :funded] do
        assert Tools.available(:evaluator, status) == []
      end
    end
  end
end
