defmodule Raxol.Agent.ClientProtocol.BudgetTest do
  @moduledoc """
  The ACP surface had no spend cap at all, so an editor or a harness could
  drive it until the provider account ran dry -- which is exactly how the first
  T-Bench smoke ended, with a 402 from a drained key.

  The cap reuses `BenchmarkProfile`, so what is worth testing here is the
  wiring: that it is off unless asked for, that `check/0` still answers when it
  is off, and that turns are refused once the money or the turn count is gone.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.BenchmarkProfile
  alias Raxol.Agent.ClientProtocol.Budget

  defp profile(env), do: BenchmarkProfile.from_env(env) |> elem(1)

  defp start(env) do
    case Budget.start_link(profile(env)) do
      {:ok, pid} -> on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
      :ignore -> :ignore
    end
  end

  describe "when no cap is configured" do
    test "it does not start, and check/0 still answers" do
      assert :ignore = Budget.start_link(profile(%{}))
      assert Budget.check() == :ok
      assert Budget.record(%{"input_tokens" => 10_000}) == :ok
      assert Budget.spent() == %{cost_usd: 0.0, turns: 0}
    end
  end

  describe "spend cap" do
    setup do
      start(%{
        "RAXOL_MAX_COST_USD" => "0.01",
        "RAXOL_COST_PER_MTOK_IN" => "1000",
        "RAXOL_COST_PER_MTOK_OUT" => "1000"
      })

      :ok
    end

    test "allows turns until the money runs out" do
      assert Budget.check() == :ok

      # 1M tokens at $1000/Mtok = $1000, well past a 1 cent cap.
      Budget.record(%{"input_tokens" => 1_000_000, "output_tokens" => 0})

      assert {:exceeded, :max_cost_usd} = Budget.check()
    end

    test "accumulates across turns rather than judging each alone" do
      for _ <- 1..3, do: Budget.record(%{"input_tokens" => 4_000, "output_tokens" => 0})

      assert %{turns: 3, cost_usd: cost} = Budget.spent()
      assert cost > 0.01
      assert {:exceeded, :max_cost_usd} = Budget.check()
    end

    # Provider usage maps arrive in both naming families; the fold is
    # BenchmarkProfile's, but a wiring slip would silently count nothing.
    test "reads OpenAI-style keys too" do
      Budget.record(%{"prompt_tokens" => 1_000_000, "completion_tokens" => 0})

      assert {:exceeded, :max_cost_usd} = Budget.check()
    end
  end

  describe "turn cap" do
    test "refuses once the turn count is spent" do
      start(%{"RAXOL_MAX_TURNS" => "2"})

      assert Budget.check() == :ok
      Budget.record(%{})
      assert Budget.check() == :ok
      Budget.record(%{})

      assert {:exceeded, :max_turns} = Budget.check()
    end
  end
end
