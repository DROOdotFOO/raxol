defmodule Raxol.Earn.Bench.RunnerTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.Bench.Runner
  alias Raxol.Earn.Bench.Runner.{Outcome, Summary}
  alias Raxol.Earn.Offering.Registry, as: OfferingRegistry
  alias Raxol.Earn.TestSupport.SellerHelper

  setup do
    OfferingRegistry.clear()

    :ok = SellerHelper.reset_seller(seller_address: "0x" <> String.duplicate("11", 20))

    {:ok, _spec} = Raxol.Earn.Bench.Offering.register()

    # Runner.run seeds the seller Queue's on-chain plumbing; clear it after
    # each test so a later test that expects no adapter isn't polluted.
    on_exit(fn ->
      Application.delete_env(:raxol_earn, :seller_provider_adapter)
      Application.delete_env(:raxol_earn, :seller_chain_id)
      Application.delete_env(:raxol_earn, :seller_acp_core_address)
    end)

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
          offering: Raxol.Earn.Bench.Offering.offering_name(),
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
          offering: Raxol.Earn.Bench.Offering.offering_name(),
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
      use Raxol.Earn.Offering, name: "raxol.bench.reject"
      @impl Raxol.Earn.Offering.Handler
      def handle_request(_req, _ctx), do: {:reject, :nope}
      @impl Raxol.Earn.Offering.Handler
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
    test "every job fails fast with no JobSession started" do
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
