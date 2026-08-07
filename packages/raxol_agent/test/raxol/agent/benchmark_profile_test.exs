defmodule Raxol.Agent.BenchmarkProfileTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.BenchmarkProfile

  describe "from_env/1" do
    test "empty env yields an inactive profile with no caps" do
      assert {:ok, profile} = BenchmarkProfile.from_env(%{})
      refute profile.active?
      assert profile.backend == nil
      assert profile.max_turns == nil
      assert profile.trajectory_path == nil
    end

    test "RAXOL_PROFILE=benchmark activates the profile" do
      assert {:ok, %{active?: true}} =
               BenchmarkProfile.from_env(%{"RAXOL_PROFILE" => "benchmark"})
    end

    test "other RAXOL_PROFILE values stay inactive" do
      assert {:ok, %{active?: false}} =
               BenchmarkProfile.from_env(%{"RAXOL_PROFILE" => "dev"})
    end

    test "RAXOL_MODEL splits provider/model against supported backends" do
      assert {:ok, profile} =
               BenchmarkProfile.from_env(%{"RAXOL_MODEL" => "mock/test-model"})

      assert profile.backend == :mock
      assert profile.model == "test-model"
    end

    test "RAXOL_MODEL keeps slashes inside the model segment" do
      assert {:ok, profile} =
               BenchmarkProfile.from_env(%{
                 "RAXOL_MODEL" => "openrouter/qwen/qwen3-coder"
               })

      assert profile.backend == :openrouter
      assert profile.model == "qwen/qwen3-coder"
    end

    test "unknown provider is a boot error naming the supported set" do
      assert {:error, message} =
               BenchmarkProfile.from_env(%{"RAXOL_MODEL" => "nope/model"})

      assert message =~ "nope"
      assert message =~ "supported"
    end

    test "RAXOL_MODEL without a slash is a boot error" do
      assert {:error, message} =
               BenchmarkProfile.from_env(%{"RAXOL_MODEL" => "claude"})

      assert message =~ "provider/model"
    end

    test "RAXOL_MAX_TURNS parses and rejects garbage" do
      assert {:ok, %{max_turns: 50}} =
               BenchmarkProfile.from_env(%{"RAXOL_MAX_TURNS" => "50"})

      assert {:error, message} =
               BenchmarkProfile.from_env(%{"RAXOL_MAX_TURNS" => "many"})

      assert message =~ "RAXOL_MAX_TURNS"

      assert {:error, _} =
               BenchmarkProfile.from_env(%{"RAXOL_MAX_TURNS" => "0"})
    end

    test "cost cap without rates is refused, not silently ignored" do
      assert {:error, message} =
               BenchmarkProfile.from_env(%{"RAXOL_MAX_COST_USD" => "5.00"})

      assert message =~ "RAXOL_COST_PER_MTOK_IN"
    end

    test "cost cap with both rates is accepted" do
      assert {:ok, profile} =
               BenchmarkProfile.from_env(%{
                 "RAXOL_MAX_COST_USD" => "5.00",
                 "RAXOL_COST_PER_MTOK_IN" => "3.0",
                 "RAXOL_COST_PER_MTOK_OUT" => "15.0"
               })

      assert profile.max_cost_usd == 5.0
      assert profile.cost_per_mtok_in == 3.0
    end
  end

  describe "budget_status/3" do
    test "no caps set never exceeds" do
      {:ok, profile} = BenchmarkProfile.from_env(%{})

      assert :ok =
               BenchmarkProfile.budget_status(profile, 1_000_000, %{
                 input_tokens: 999_999_999,
                 output_tokens: 999_999_999
               })
    end

    test "turn cap trips at the cap, not before" do
      {:ok, profile} = BenchmarkProfile.from_env(%{"RAXOL_MAX_TURNS" => "3"})

      assert :ok = BenchmarkProfile.budget_status(profile, 2, %{})

      assert {:exceeded, :max_turns} =
               BenchmarkProfile.budget_status(profile, 3, %{})
    end

    test "cost cap trips from accumulated token usage" do
      {:ok, profile} =
        BenchmarkProfile.from_env(%{
          "RAXOL_MAX_COST_USD" => "1.00",
          "RAXOL_COST_PER_MTOK_IN" => "10.0",
          "RAXOL_COST_PER_MTOK_OUT" => "10.0"
        })

      under = %{input_tokens: 40_000, output_tokens: 40_000}
      over = %{input_tokens: 60_000, output_tokens: 60_000}

      assert :ok = BenchmarkProfile.budget_status(profile, 0, under)

      assert {:exceeded, :max_cost_usd} =
               BenchmarkProfile.budget_status(profile, 0, over)
    end
  end

  describe "add_usage/2" do
    test "accumulates Anthropic-style atom keys" do
      acc = %{input_tokens: 10, output_tokens: 20}

      assert %{input_tokens: 110, output_tokens: 220} =
               BenchmarkProfile.add_usage(acc, %{
                 input_tokens: 100,
                 output_tokens: 200
               })
    end

    test "accumulates OpenAI-style string keys" do
      acc = %{input_tokens: 0, output_tokens: 0}

      assert %{input_tokens: 100, output_tokens: 200} =
               BenchmarkProfile.add_usage(acc, %{
                 "prompt_tokens" => 100,
                 "completion_tokens" => 200
               })
    end

    test "empty or malformed usage adds nothing" do
      acc = %{input_tokens: 5, output_tokens: 5}
      assert ^acc = BenchmarkProfile.add_usage(acc, %{})
      assert ^acc = BenchmarkProfile.add_usage(acc, %{input_tokens: "lots"})
      assert ^acc = BenchmarkProfile.add_usage(acc, nil)
    end
  end
end
