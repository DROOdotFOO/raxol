defmodule Raxol.Symphony.Sandboxes.BudgetCapTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Sandbox
  alias Raxol.Symphony.Sandboxes.BudgetCap

  defp unique_table, do: :"bc_test_#{:erlang.unique_integer([:positive])}"

  defp sandbox(opts \\ []) do
    %BudgetCap{
      cap: Keyword.get(opts, :cap, 3),
      cost_per_turn: Keyword.get(opts, :cost_per_turn, 1),
      id_fn: Keyword.get(opts, :id_fn, &BudgetCap.default_id_fn/1),
      bucket_table: Keyword.get(opts, :bucket_table, unique_table())
    }
  end

  defp authorize(sb, payload, action \\ :turn) do
    Sandbox.authorize(sb, action, payload, %{})
  end

  describe "Sandbox protocol -- :turn action" do
    test "allows turns until cumulative cost would exceed cap" do
      sb = sandbox(cap: 3, cost_per_turn: 1)

      assert :ok = authorize(sb, %{issue_id: "iss-1"})
      assert :ok = authorize(sb, %{issue_id: "iss-1"})
      assert :ok = authorize(sb, %{issue_id: "iss-1"})
      assert {:deny, :budget_exceeded} = authorize(sb, %{issue_id: "iss-1"})
    end

    test "respects cost_per_turn > 1" do
      sb = sandbox(cap: 10, cost_per_turn: 4)

      assert :ok = authorize(sb, %{issue_id: "iss-1"})
      assert :ok = authorize(sb, %{issue_id: "iss-1"})
      # 4 + 4 + 4 = 12 > 10
      assert {:deny, :budget_exceeded} = authorize(sb, %{issue_id: "iss-1"})
    end

    test "identifiers are tracked independently" do
      sb = sandbox(cap: 1, cost_per_turn: 1)

      assert :ok = authorize(sb, %{issue_id: "iss-a"})
      assert :ok = authorize(sb, %{issue_id: "iss-b"})

      assert {:deny, :budget_exceeded} = authorize(sb, %{issue_id: "iss-a"})
      assert {:deny, :budget_exceeded} = authorize(sb, %{issue_id: "iss-b"})
    end

    test "missing identifier abstains" do
      sb = sandbox(cap: 0)

      # cap: 0 would deny if identifier were present; absence yields :ok.
      assert :ok = authorize(sb, %{})
      assert :ok = authorize(sb, %{some_other_key: "x"})
    end

    test "custom id_fn allows org-level scoping" do
      sb =
        sandbox(
          cap: 2,
          cost_per_turn: 1,
          id_fn: fn payload -> Map.get(payload, :org_id) end
        )

      assert :ok = authorize(sb, %{issue_id: "iss-1", org_id: "org-a"})
      assert :ok = authorize(sb, %{issue_id: "iss-2", org_id: "org-a"})

      # Same org, third turn -> denied.
      assert {:deny, :budget_exceeded} =
               authorize(sb, %{issue_id: "iss-3", org_id: "org-a"})

      # Different org -> allowed.
      assert :ok = authorize(sb, %{issue_id: "iss-1", org_id: "org-b"})
    end

    test "custom id_fn returning a constant gives a global budget" do
      sb =
        sandbox(cap: 2, cost_per_turn: 1, id_fn: fn _ -> :global end)

      assert :ok = authorize(sb, %{issue_id: "iss-1"})
      assert :ok = authorize(sb, %{issue_id: "iss-2"})
      assert {:deny, :budget_exceeded} = authorize(sb, %{issue_id: "iss-3"})
    end
  end

  describe "Sandbox protocol -- other actions abstain" do
    test "non-:turn actions return :ok regardless of cap" do
      sb = sandbox(cap: 0)

      assert :ok = authorize(sb, %{issue_id: "iss-1"}, :shell)
      assert :ok = authorize(sb, %{issue_id: "iss-1"}, :send_agent)
      assert :ok = authorize(sb, %{issue_id: "iss-1"}, :async)
    end
  end

  describe "spend/2" do
    test "returns 0 for unknown identifiers" do
      table = unique_table()
      assert BudgetCap.spend(table, "iss-1") == 0
    end

    test "returns the running cumulative spend" do
      sb = sandbox(cap: 5, cost_per_turn: 2)

      :ok = authorize(sb, %{issue_id: "iss-1"})
      :ok = authorize(sb, %{issue_id: "iss-1"})

      assert BudgetCap.spend(sb.bucket_table, "iss-1") == 4
    end
  end

  describe "reset/2" do
    test "clears a single identifier's spend" do
      sb = sandbox(cap: 1, cost_per_turn: 1)

      assert :ok = authorize(sb, %{issue_id: "iss-1"})
      assert {:deny, :budget_exceeded} = authorize(sb, %{issue_id: "iss-1"})

      BudgetCap.reset(sb.bucket_table, "iss-1")

      assert :ok = authorize(sb, %{issue_id: "iss-1"})
    end

    test ":all clears the whole table" do
      sb = sandbox(cap: 1, cost_per_turn: 1)

      :ok = authorize(sb, %{issue_id: "iss-a"})
      :ok = authorize(sb, %{issue_id: "iss-b"})

      BudgetCap.reset(sb.bucket_table, :all)

      assert :ok = authorize(sb, %{issue_id: "iss-a"})
      assert :ok = authorize(sb, %{issue_id: "iss-b"})
    end

    test "reset on unknown identifier is idempotent" do
      table = unique_table()
      assert :ok = BudgetCap.reset(table, "ghost")
    end
  end

  describe "ensure_table/1" do
    test "creates a new ETS table on first call" do
      table = unique_table()
      assert :ets.whereis(table) == :undefined

      assert ^table = BudgetCap.ensure_table(table)
      assert :ets.whereis(table) != :undefined

      :ets.delete(table)
    end

    test "is idempotent" do
      table = unique_table()
      _ = BudgetCap.ensure_table(table)
      ref = :ets.whereis(table)
      _ = BudgetCap.ensure_table(table)
      assert :ets.whereis(table) == ref

      :ets.delete(table)
    end
  end
end
