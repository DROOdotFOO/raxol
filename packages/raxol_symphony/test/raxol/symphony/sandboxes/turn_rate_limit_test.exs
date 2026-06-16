defmodule Raxol.Symphony.Sandboxes.TurnRateLimitTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Sandbox
  alias Raxol.Symphony.Sandboxes.TurnRateLimit

  defp sandbox(opts \\ []) do
    %TurnRateLimit{
      max_turns: Keyword.get(opts, :max_turns, 3),
      window_ms: Keyword.get(opts, :window_ms, 1_000),
      bucket_table:
        Keyword.get(
          opts,
          :bucket_table,
          :"trl_test_#{:erlang.unique_integer([:positive])}"
        )
    }
  end

  setup do
    on_exit(fn ->
      for {tab, _} <- :ets.all() |> List.flatten() |> List.wrap(),
          is_atom(tab) and String.starts_with?(Atom.to_string(tab), "trl_test_"),
          :ets.whereis(tab) != :undefined do
        :ets.delete(tab)
      end
    end)

    :ok
  end

  defp authorize(sb, issue_id, action \\ :turn) do
    Sandbox.authorize(sb, action, %{issue_id: issue_id, turn: 1}, %{})
  end

  describe "Sandbox protocol -- :turn action" do
    test "allows the first N turns within the window" do
      sb = sandbox(max_turns: 3)

      assert :ok = authorize(sb, "iss-1")
      assert :ok = authorize(sb, "iss-1")
      assert :ok = authorize(sb, "iss-1")
    end

    test "denies the N+1th turn with :rate_limited" do
      sb = sandbox(max_turns: 2)

      assert :ok = authorize(sb, "iss-1")
      assert :ok = authorize(sb, "iss-1")
      assert {:deny, :rate_limited} = authorize(sb, "iss-1")
    end

    test "issues are tracked independently" do
      sb = sandbox(max_turns: 1)

      assert :ok = authorize(sb, "iss-a")
      assert :ok = authorize(sb, "iss-b")
      assert :ok = authorize(sb, "iss-c")

      # Each issue's bucket is independent.
      assert {:deny, :rate_limited} = authorize(sb, "iss-a")
      assert {:deny, :rate_limited} = authorize(sb, "iss-b")
    end

    test "older entries are pruned past the window" do
      # 1-turn budget, 50ms window. Use 1 turn, sleep > 50ms, get
      # another turn back.
      sb = sandbox(max_turns: 1, window_ms: 50)

      assert :ok = authorize(sb, "iss-1")
      assert {:deny, :rate_limited} = authorize(sb, "iss-1")

      Process.sleep(80)

      assert :ok = authorize(sb, "iss-1")
    end
  end

  describe "Sandbox protocol -- other actions abstain" do
    test "non-:turn actions return :ok regardless of bucket state" do
      sb = sandbox(max_turns: 0)

      # Even with max_turns: 0 (no :turn ever allowed), other actions
      # pass through.
      assert :ok = authorize(sb, "iss-1", :shell)
      assert :ok = authorize(sb, "iss-1", :send_agent)
      assert :ok = authorize(sb, "iss-1", :async)
    end
  end

  describe "ensure_table/1" do
    test "creates a new ETS table on first call" do
      table = :"trl_test_#{:erlang.unique_integer([:positive])}"
      assert :ets.whereis(table) == :undefined

      assert ^table = TurnRateLimit.ensure_table(table)
      assert :ets.whereis(table) != :undefined

      :ets.delete(table)
    end

    test "is idempotent (second call no-ops)" do
      table = :"trl_test_#{:erlang.unique_integer([:positive])}"
      _ = TurnRateLimit.ensure_table(table)

      ref_after_first = :ets.whereis(table)
      _ = TurnRateLimit.ensure_table(table)

      assert :ets.whereis(table) == ref_after_first

      :ets.delete(table)
    end
  end
end
