defmodule Raxol.ACP.ContractClientTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory

  @seller "0x" <> String.duplicate("ab", 20)

  setup do
    InMemory.reset()
    :ok
  end

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
    test "returns a synthetic job_id and tracks the job" do
      assert {:ok, "job-1"} = ContractClient.create_job(@seller, Decimal.new("0.50"), <<1, 2>>)
      assert {:ok, "job-2"} = ContractClient.create_job(@seller, Decimal.new("1.00"), <<3, 4>>)

      assert InMemory.list_jobs() == ["job-1", "job-2"]

      job1 = InMemory.get_job("job-1")
      assert job1.seller == @seller
      assert Decimal.equal?(job1.price, Decimal.new("0.50"))
      assert job1.data == <<1, 2>>
      assert job1.memos == []
      refute job1.completed
    end
  end

  describe "submit_memo/4 (delegated)" do
    test "appends memos in submission order with synthetic tx_hashes" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("1.00"), <<>>)

      assert {:ok, "tx-1"} =
               ContractClient.submit_memo(job_id, :request, %{x: 1}, <<0xAA>>)

      assert {:ok, "tx-2"} =
               ContractClient.submit_memo(job_id, :negotiation, %{x: 2}, <<0xBB>>)

      memos = InMemory.list_memos(job_id)
      assert length(memos) == 2
      assert [%{type: :request}, %{type: :negotiation}] = memos
      assert Enum.map(memos, & &1.tx_hash) == ["tx-1", "tx-2"]
    end

    test "errors on unknown job" do
      assert {:error, {:no_such_job, "job-bogus"}} =
               ContractClient.submit_memo("job-bogus", :request, %{}, <<>>)
    end
  end

  describe "complete_job/2 (delegated)" do
    test "marks job completed and records the deliverable hash" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("1.00"), <<>>)
      hash = :crypto.hash(:sha256, "deliverable")

      assert {:ok, "tx-1"} = ContractClient.complete_job(job_id, hash)

      job = InMemory.get_job(job_id)
      assert job.completed
      assert job.deliverable_hash == hash
    end

    test "errors on unknown job" do
      assert {:error, {:no_such_job, "nope"}} =
               ContractClient.complete_job("nope", <<0::256>>)
    end
  end

  describe "pay_and_accept_requirement/2 (delegated)" do
    test "records the authorization payload" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("1.00"), <<>>)
      auth = <<0xDE, 0xAD, 0xBE, 0xEF>>

      assert {:ok, "tx-1"} = ContractClient.pay_and_accept_requirement(job_id, auth)

      assert InMemory.get_job(job_id).payment_authorization == auth
    end
  end

  describe "tx_hash counter is global across all calls" do
    test "tx-1, tx-2, tx-3 across mixed methods" do
      {:ok, j} = ContractClient.create_job(@seller, Decimal.new("1.00"), <<>>)

      assert {:ok, "tx-1"} = ContractClient.submit_memo(j, :request, %{}, <<>>)
      assert {:ok, "tx-2"} = ContractClient.pay_and_accept_requirement(j, <<>>)
      assert {:ok, "tx-3"} = ContractClient.complete_job(j, <<0::256>>)
    end
  end

  describe "reset/0" do
    test "wipes all state" do
      {:ok, _} = ContractClient.create_job(@seller, Decimal.new("1.00"), <<>>)
      assert InMemory.list_jobs() != []

      InMemory.reset()
      assert InMemory.list_jobs() == []

      # Counters reset too -- next job_id is "job-1" again
      assert {:ok, "job-1"} = ContractClient.create_job(@seller, Decimal.new("1.00"), <<>>)
    end
  end
end
