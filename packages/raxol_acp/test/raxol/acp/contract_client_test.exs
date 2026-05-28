defmodule Raxol.ACP.ContractClientTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory

  @provider "0x" <> String.duplicate("ab", 20)
  @evaluator "0x" <> String.duplicate("cd", 20)
  @expired_at 9_999_999_999

  setup do
    InMemory.reset()
    :ok
  end

  defp new_job, do: ContractClient.create_job(@provider, @evaluator, @expired_at)

  describe "impl/0" do
    test "returns the configured impl" do
      assert ContractClient.impl() == InMemory
    end

    test "raises a helpful error when unset" do
      Application.delete_env(:raxol_acp, :contract_client)

      assert_raise RuntimeError, ~r/no contract client configured/, fn ->
        ContractClient.impl()
      end
    end

    setup do
      on_exit(fn ->
        Application.put_env(:raxol_acp, :contract_client, InMemory)
      end)
    end
  end

  describe "create_job/3 (delegated)" do
    test "returns a synthetic job_id and tracks provider/evaluator/expiry" do
      assert {:ok, "job-1"} = new_job()
      assert {:ok, "job-2"} = new_job()

      assert InMemory.list_jobs() == ["job-1", "job-2"]

      job1 = InMemory.get_job("job-1")
      assert job1.provider == @provider
      assert job1.evaluator == @evaluator
      assert job1.expired_at == @expired_at
      assert job1.budget == nil
      assert job1.memos == []
      refute job1.claimed
    end
  end

  describe "set_budget/2 (delegated)" do
    test "records the budget in USDC" do
      {:ok, job_id} = new_job()
      assert {:ok, "tx-1"} = ContractClient.set_budget(job_id, Decimal.new("0.50"))
      assert Decimal.equal?(InMemory.get_job(job_id).budget, Decimal.new("0.50"))
    end

    test "errors on unknown job" do
      assert {:error, {:no_such_job, "nope"}} =
               ContractClient.set_budget("nope", Decimal.new("1.00"))
    end
  end

  describe "create_memo/5 (delegated)" do
    test "appends memos in submission order with synthetic tx_hashes" do
      {:ok, job_id} = new_job()

      assert {:ok, "tx-1"} =
               ContractClient.create_memo(job_id, "first", :message, false, :negotiation)

      assert {:ok, "tx-2"} =
               ContractClient.create_memo(job_id, "second", :txhash, true, :transaction)

      memos = InMemory.list_memos(job_id)
      assert length(memos) == 2

      assert [
               %{
                 memo_type: :message,
                 next_phase: :negotiation,
                 content: "first",
                 is_secured: false
               },
               %{
                 memo_type: :txhash,
                 next_phase: :transaction,
                 content: "second",
                 is_secured: true
               }
             ] = memos

      assert Enum.map(memos, & &1.tx_hash) == ["tx-1", "tx-2"]
    end

    test "errors on unknown job" do
      assert {:error, {:no_such_job, "job-bogus"}} =
               ContractClient.create_memo("job-bogus", "x", :message, false, :negotiation)
    end
  end

  describe "sign_memo/3 (delegated)" do
    test "records the sign (approve/reject + reason) keyed by memo id" do
      {:ok, _job_id} = new_job()

      assert {:ok, "tx-1"} = ContractClient.sign_memo(7, true, "looks good")
      assert {:ok, "tx-2"} = ContractClient.sign_memo(8, false, "missing data")

      assert [
               %{memo_id: 7, approved: true, reason: "looks good"},
               %{memo_id: 8, approved: false, reason: "missing data"}
             ] = InMemory.list_signs()
    end
  end

  describe "claim_budget/1 (delegated)" do
    test "marks the job claimed" do
      {:ok, job_id} = new_job()
      assert {:ok, "tx-1"} = ContractClient.claim_budget(job_id)
      assert InMemory.get_job(job_id).claimed
    end

    test "errors on unknown job" do
      assert {:error, {:no_such_job, "nope"}} = ContractClient.claim_budget("nope")
    end
  end

  describe "set_budget_with_payment_token/3 (delegated)" do
    test "records the budget and the token address" do
      {:ok, job_id} = new_job()
      token = "0x" <> String.duplicate("ee", 20)

      assert {:ok, "tx-1"} =
               ContractClient.set_budget_with_payment_token(job_id, Decimal.new("2.50"), token)

      job = InMemory.get_job(job_id)
      assert Decimal.equal?(job.budget, Decimal.new("2.50"))
      assert job.payment_token == token
    end
  end

  describe "confirm_x402_payment_received/1 (delegated)" do
    test "marks the job's x402 payment confirmed" do
      {:ok, job_id} = new_job()
      assert {:ok, "tx-1"} = ContractClient.confirm_x402_payment_received(job_id)
      assert InMemory.get_job(job_id).x402_confirmed
    end
  end

  describe "create_payable_memo/3 (delegated)" do
    test "records a payable memo with token/amount/recipient and defaults" do
      {:ok, job_id} = new_job()
      token = "0x" <> String.duplicate("ee", 20)
      recipient = "0x" <> String.duplicate("ff", 20)

      assert {:ok, "tx-1"} =
               ContractClient.create_payable_memo(job_id, "settle",
                 token: token,
                 amount: Decimal.new("1.00"),
                 recipient: recipient,
                 next_phase: :transaction
               )

      [memo] = InMemory.list_memos(job_id)
      assert memo.payable
      assert memo.token == token
      assert Decimal.equal?(memo.amount, Decimal.new("1.00"))
      assert memo.recipient == recipient
      assert memo.next_phase == :transaction
      # Defaults
      assert memo.fee_type == :no_fee
      assert memo.memo_type == :payable_request
      assert Decimal.equal?(memo.fee_amount, Decimal.new(0))
      assert memo.expired_at == 0
    end

    test "honors explicit fee_type, memo_type, fee_amount, expired_at" do
      {:ok, job_id} = new_job()

      assert {:ok, "tx-1"} =
               ContractClient.create_payable_memo(job_id, "settle",
                 token: "0x" <> String.duplicate("ee", 20),
                 amount: Decimal.new("1.00"),
                 recipient: "0x" <> String.duplicate("ff", 20),
                 fee_amount: Decimal.new("0.05"),
                 fee_type: :percentage_fee,
                 memo_type: :payable_transfer,
                 next_phase: :completed,
                 expired_at: 9_999_999_999
               )

      [memo] = InMemory.list_memos(job_id)
      assert memo.fee_type == :percentage_fee
      assert memo.memo_type == :payable_transfer
      assert Decimal.equal?(memo.fee_amount, Decimal.new("0.05"))
      assert memo.expired_at == 9_999_999_999
    end
  end

  describe "tx_hash counter is global across all calls" do
    test "tx-1, tx-2, tx-3 across mixed methods" do
      {:ok, j} = new_job()

      assert {:ok, "tx-1"} = ContractClient.set_budget(j, Decimal.new("1.00"))
      assert {:ok, "tx-2"} = ContractClient.create_memo(j, "x", :message, false, :negotiation)
      assert {:ok, "tx-3"} = ContractClient.claim_budget(j)
    end
  end

  describe "reset/0" do
    test "wipes all state" do
      {:ok, _} = new_job()
      assert InMemory.list_jobs() != []

      InMemory.reset()
      assert InMemory.list_jobs() == []

      # Counters reset too -- next job_id is "job-1" again
      assert {:ok, "job-1"} = new_job()
    end
  end
end
