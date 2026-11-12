defmodule Raxol.Agent.ClientProtocol.BudgetTest do
  @moduledoc """
  The cap alone: which variables start it, that a turn is counted when it is
  taken, that spend is what replies reported, and that a cap whose process
  is gone refuses.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.Budget

  @cost_cap %{
    "RAXOL_MAX_COST_USD" => "0.01",
    "RAXOL_COST_PER_MTOK_IN" => "1000",
    "RAXOL_COST_PER_MTOK_OUT" => "1000"
  }

  defp start(env), do: start_supervised!({Budget, env})

  describe "start_link/1" do
    test "does not start without a cap, and no cap allows every turn" do
      assert Budget.start_link(%{}) == :ignore
      assert Budget.begin_turn(nil) == :ok
      assert Budget.record_usage(nil, %{"input_tokens" => 10_000}) == :ok
    end

    test "reads the cap variables and no other" do
      assert Budget.start_link(%{"RAXOL_MODEL" => "not a model"}) == :ignore
    end

    test "refuses a cap it cannot read or enforce" do
      assert {:error, message} = Budget.start_link(%{"RAXOL_MAX_TURNS" => "many"})
      assert message =~ "RAXOL_MAX_TURNS"

      assert {:error, message} = Budget.start_link(%{"RAXOL_MAX_COST_USD" => "1"})
      assert message =~ "RAXOL_COST_PER_MTOK_IN"
    end
  end

  describe "turn cap" do
    test "a turn counts when it is taken, and the cap refuses the next" do
      budget = start(%{"RAXOL_MAX_TURNS" => "2"})

      assert Budget.begin_turn(budget) == :ok
      assert Budget.begin_turn(budget) == :ok
      assert Budget.begin_turn(budget) == {:exceeded, :max_turns}
      assert Budget.spent(budget).turns == 2
    end

    test "turns taken at once never pass the cap" do
      budget = start(%{"RAXOL_MAX_TURNS" => "3"})

      taken =
        1..20
        |> Task.async_stream(fn _n -> Budget.begin_turn(budget) end, max_concurrency: 20)
        |> Enum.count(&(&1 == {:ok, :ok}))

      assert taken == 3
    end
  end

  describe "spend cap" do
    test "allows turns until the reported spend passes it" do
      budget = start(@cost_cap)
      assert Budget.begin_turn(budget) == :ok

      # 1M tokens at $1000/Mtok = $1000, well past a 1 cent cap.
      Budget.record_usage(budget, %{"input_tokens" => 1_000_000, "output_tokens" => 0})

      assert Budget.begin_turn(budget) == {:exceeded, :max_cost_usd}
    end

    test "adds up what replies reported, in either naming family" do
      budget = start(@cost_cap)

      Budget.record_usage(budget, %{"input_tokens" => 4_000, "output_tokens" => 0})
      Budget.record_usage(budget, %{"prompt_tokens" => 4_000, "completion_tokens" => 4_000})

      assert %{turns: 0, cost_usd: cost} = Budget.spent(budget)
      assert_in_delta cost, 12.0, 0.001
      assert Budget.begin_turn(budget) == {:exceeded, :max_cost_usd}
    end
  end

  describe "a cap whose process is gone" do
    test "refuses the turn" do
      budget = start(%{"RAXOL_MAX_TURNS" => "5"})
      :ok = stop_supervised(Budget)

      assert Budget.begin_turn(budget) == {:exceeded, :cap_unavailable}
      assert Budget.record_usage(budget, %{}) == :ok
    end
  end
end
