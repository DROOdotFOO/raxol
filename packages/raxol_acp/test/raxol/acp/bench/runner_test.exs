defmodule Raxol.ACP.Bench.RunnerTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Bench.Runner
  alias Raxol.ACP.Bench.Runner.{Outcome, Summary}
  alias Raxol.ACP.Offering.Registry, as: OfferingRegistry
  alias Raxol.ACP.TestSupport.SellerHelper

  @env_var "RAXOL_ACP_BENCH_PRIVKEY"
  @anvil_test_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @memo_opts [chain_id: 8453, verifying_contract: "0x" <> String.duplicate("ab", 20)]

  setup do
    System.put_env(@env_var, @anvil_test_key)
    on_exit(fn -> System.delete_env(@env_var) end)

    OfferingRegistry.clear()

    :ok =
      SellerHelper.reset_seller(
        wallet: Raxol.ACP.Bench.Wallet,
        memo_opts: @memo_opts,
        seller_address: "0x" <> String.duplicate("11", 20)
      )

    {:ok, _spec} = Raxol.ACP.Bench.Offering.register()

    :ok
  end

  describe "longest_run/2" do
    test "returns 0 for empty input" do
      assert Runner.longest_run([], :success) == 0
    end

    test "returns 0 when target never appears" do
      assert Runner.longest_run([:failure, :failure, :failure], :success) == 0
    end

    test "returns the length of a single uninterrupted run" do
      assert Runner.longest_run([:success, :success, :success], :success) == 3
    end

    test "returns the length of the longest run when broken up" do
      statuses = [:success, :success, :failure, :success, :success, :success, :failure]
      assert Runner.longest_run(statuses, :success) == 3
    end

    test "single success counts as 1" do
      assert Runner.longest_run([:failure, :success, :failure], :success) == 1
    end
  end

  describe "run/1 with the auto-registered Bench.Offering" do
    test "all jobs succeed under default settings" do
      summary =
        Runner.run(
          offering: Raxol.ACP.Bench.Offering.offering_name(),
          jobs: 5,
          gate: 3,
          job_timeout_ms: 2_000
        )

      assert %Summary{} = summary
      assert summary.successes == 5
      assert summary.failures == 0
      assert summary.longest_consecutive_successes == 5
      assert summary.gate == 3
      assert summary.gate_met?
      assert is_integer(summary.elapsed_ms) and summary.elapsed_ms >= 0

      assert length(summary.jobs) == 5

      for outcome <- summary.jobs do
        assert %Outcome{status: :success, reason: nil} = outcome
        assert is_binary(outcome.job_id)
        assert outcome.elapsed_ms >= 0
      end
    end

    test "gate_met? is false when gate exceeds longest run" do
      summary =
        Runner.run(
          offering: Raxol.ACP.Bench.Offering.offering_name(),
          jobs: 3,
          gate: 100,
          job_timeout_ms: 2_000
        )

      assert summary.successes == 3
      assert summary.longest_consecutive_successes == 3
      refute summary.gate_met?
    end
  end

  describe "run/1 with a deliberately broken offering" do
    defmodule RejectAllOffering do
      use Raxol.ACP.Offering, name: "raxol.bench.reject"
      @impl Raxol.ACP.Offering.Handler
      def handle_request(_req, _ctx), do: {:reject, :nope}
      @impl Raxol.ACP.Offering.Handler
      def handle_deliver(_req, _ctx), do: {:deliver, %{}}
    end

    test "every job fails when the offering rejects requests" do
      {:ok, _spec} = RejectAllOffering.register()

      summary =
        Runner.run(
          offering: "raxol.bench.reject",
          jobs: 3,
          gate: 1,
          job_timeout_ms: 500
        )

      assert summary.successes == 0
      assert summary.failures == 3
      assert summary.longest_consecutive_successes == 0
      refute summary.gate_met?

      for outcome <- summary.jobs do
        assert outcome.status == :failure
        assert outcome.reason != nil
      end
    end
  end

  describe "run/1 with unknown offering" do
    test "every job fails fast with no Job.Server started" do
      summary =
        Runner.run(
          offering: "raxol.bench.never.registered",
          jobs: 2,
          gate: 1,
          job_timeout_ms: 200
        )

      assert summary.successes == 0
      assert summary.failures == 2
      assert summary.longest_consecutive_successes == 0
      refute summary.gate_met?
    end
  end
end
