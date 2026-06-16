defmodule Raxol.ACP.DirectiveTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Directive

  alias Raxol.ACP.Directive.{
    ClaimBudget,
    ConfirmX402Payment,
    CreateJob,
    CreateMemo,
    CreatePayableMemo,
    SetBudget,
    SetBudgetWithPaymentToken,
    SignMemo
  }

  alias Raxol.Core.Runtime.Directive.Executor

  setup do
    InMemory.reset()
    :ok
  end

  describe "constructors" do
    test "create_job/1 builds struct from required fields" do
      d =
        Directive.create_job(
          provider: "0xaaaa",
          evaluator: "0xbbbb",
          expired_at: 1_700_000_000
        )

      assert %CreateJob{
               provider: "0xaaaa",
               evaluator: "0xbbbb",
               expired_at: 1_700_000_000,
               meta: %{}
             } = d
    end

    test "create_job/1 raises without required fields" do
      assert_raise KeyError, fn ->
        Directive.create_job(provider: "0xa", evaluator: "0xb")
      end
    end

    test "set_budget/1 carries amount" do
      d = Directive.set_budget(job_id: "job-1", amount: Decimal.new("1.50"))
      assert %SetBudget{job_id: "job-1", amount: %Decimal{}} = d
    end

    test "set_budget_with_payment_token/1 carries token" do
      d =
        Directive.set_budget_with_payment_token(
          job_id: "job-1",
          amount: Decimal.new("1.50"),
          token: "0xtoken"
        )

      assert %SetBudgetWithPaymentToken{
               job_id: "job-1",
               token: "0xtoken"
             } = d
    end

    test "create_memo/1 defaults is_secured to false" do
      d =
        Directive.create_memo(
          job_id: "job-1",
          content: "hello",
          memo_type: :message,
          next_phase: :negotiation
        )

      assert %CreateMemo{is_secured: false, memo_type: :message} = d
    end

    test "create_memo/1 respects is_secured override" do
      d =
        Directive.create_memo(
          job_id: "job-1",
          content: "hello",
          memo_type: :message,
          next_phase: :negotiation,
          is_secured: true
        )

      assert d.is_secured == true
    end

    test "create_payable_memo/1 carries opts" do
      opts = [
        token: "0xtoken",
        amount: Decimal.new("1.0"),
        recipient: "0xrecip",
        next_phase: :transaction
      ]

      d =
        Directive.create_payable_memo(
          job_id: "job-1",
          content: "pay",
          opts: opts
        )

      assert %CreatePayableMemo{opts: ^opts} = d
    end

    test "sign_memo/1 supports integer and binary memo_id" do
      assert %SignMemo{memo_id: 42} =
               Directive.sign_memo(memo_id: 42, approved: true, reason: "ok")

      assert %SignMemo{memo_id: "memo-1"} =
               Directive.sign_memo(
                 memo_id: "memo-1",
                 approved: false,
                 reason: "no"
               )
    end

    test "claim_budget/1 and confirm_x402_payment/1 require job_id" do
      assert %ClaimBudget{job_id: "job-1"} =
               Directive.claim_budget(job_id: "job-1")

      assert %ConfirmX402Payment{job_id: "job-1"} =
               Directive.confirm_x402_payment(job_id: "job-1")
    end

    test "meta defaults to empty map and round-trips" do
      d = Directive.claim_budget(job_id: "job-1", meta: %{caller: :agent_a})
      assert d.meta == %{caller: :agent_a}
    end
  end

  describe "Executor: CreateJob" do
    test "successful create_job sends acp_create_job_result with job id" do
      d =
        Directive.create_job(
          provider: "0xaaaa",
          evaluator: "0xbbbb",
          expired_at: 1_700_000_000
        )

      Executor.execute(d, ctx())
      assert_receive {:command_result, {:acp_create_job_result, "job-1"}}, 1_000
    end
  end

  describe "Executor: SetBudget" do
    test "sets budget and replies with tx_hash" do
      {:ok, job_id} = InMemory.create_job("0xa", "0xb", 1_700_000_000)
      d = Directive.set_budget(job_id: job_id, amount: Decimal.new("2.5"))

      Executor.execute(d, ctx())

      assert_receive {:command_result, {:acp_set_budget_result, "tx-" <> _}},
                     1_000
    end

    test "missing job replies with acp_set_budget_error" do
      d = Directive.set_budget(job_id: "missing", amount: Decimal.new("1.0"))
      Executor.execute(d, ctx())
      assert_receive {:command_result, {:acp_set_budget_error, _reason}}, 1_000
    end
  end

  describe "Executor: SetBudgetWithPaymentToken" do
    test "sets budget with token" do
      {:ok, job_id} = InMemory.create_job("0xa", "0xb", 1_700_000_000)

      d =
        Directive.set_budget_with_payment_token(
          job_id: job_id,
          amount: Decimal.new("3.0"),
          token: "0xtoken"
        )

      Executor.execute(d, ctx())

      assert_receive {:command_result,
                      {:acp_set_budget_with_payment_token_result, "tx-" <> _}},
                     1_000
    end
  end

  describe "Executor: CreateMemo" do
    test "creates a memo with tx_hash" do
      {:ok, job_id} = InMemory.create_job("0xa", "0xb", 1_700_000_000)

      d =
        Directive.create_memo(
          job_id: job_id,
          content: "ack",
          memo_type: :message,
          next_phase: :negotiation
        )

      Executor.execute(d, ctx())

      assert_receive {:command_result, {:acp_create_memo_result, "tx-" <> _}},
                     1_000
    end

    test "errors when job not found" do
      d =
        Directive.create_memo(
          job_id: "missing",
          content: "ack",
          memo_type: :message,
          next_phase: :negotiation
        )

      Executor.execute(d, ctx())
      assert_receive {:command_result, {:acp_create_memo_error, _reason}}, 1_000
    end
  end

  describe "Executor: CreatePayableMemo" do
    test "creates a payable memo" do
      {:ok, job_id} = InMemory.create_job("0xa", "0xb", 1_700_000_000)

      d =
        Directive.create_payable_memo(
          job_id: job_id,
          content: "pay",
          opts: [
            token: "0xtoken",
            amount: Decimal.new("1.0"),
            recipient: "0xrecip",
            next_phase: :transaction
          ]
        )

      Executor.execute(d, ctx())

      assert_receive {:command_result,
                      {:acp_create_payable_memo_result, "tx-" <> _}},
                     1_000
    end
  end

  describe "Executor: SignMemo" do
    test "signs an approval" do
      d = Directive.sign_memo(memo_id: "memo-1", approved: true, reason: "ok")
      Executor.execute(d, ctx())

      assert_receive {:command_result, {:acp_sign_memo_result, "tx-" <> _}},
                     1_000
    end

    test "signs a rejection" do
      d = Directive.sign_memo(memo_id: 7, approved: false, reason: "no")
      Executor.execute(d, ctx())

      assert_receive {:command_result, {:acp_sign_memo_result, "tx-" <> _}},
                     1_000
    end
  end

  describe "Executor: ClaimBudget" do
    test "claims for an existing job" do
      {:ok, job_id} = InMemory.create_job("0xa", "0xb", 1_700_000_000)
      d = Directive.claim_budget(job_id: job_id)
      Executor.execute(d, ctx())

      assert_receive {:command_result, {:acp_claim_budget_result, "tx-" <> _}},
                     1_000
    end

    test "errors when job not found" do
      d = Directive.claim_budget(job_id: "missing")
      Executor.execute(d, ctx())

      assert_receive {:command_result, {:acp_claim_budget_error, _reason}},
                     1_000
    end
  end

  describe "Executor: ConfirmX402Payment" do
    test "confirms for an existing job" do
      {:ok, job_id} = InMemory.create_job("0xa", "0xb", 1_700_000_000)
      d = Directive.confirm_x402_payment(job_id: job_id)
      Executor.execute(d, ctx())

      assert_receive {:command_result, {:acp_confirm_x402_result, "tx-" <> _}},
                     1_000
    end
  end

  describe "Executor: exception path" do
    test "raised exception routes through acp_<op>_error with {:exception, msg}" do
      # Point at an unconfigured contract client so impl/0 raises.
      original = Application.get_env(:raxol_acp, :contract_client)

      try do
        Application.delete_env(:raxol_acp, :contract_client)

        d = Directive.claim_budget(job_id: "job-1")
        Executor.execute(d, ctx())

        assert_receive {:command_result,
                        {:acp_claim_budget_error, {:exception, msg}}},
                       1_000

        assert is_binary(msg)
      after
        Application.put_env(:raxol_acp, :contract_client, original)
      end
    end
  end

  defp ctx, do: %{pid: self(), runtime_pid: self()}

  describe "Helper.execute_sync/2 (Phase 24 D-6)" do
    alias Raxol.ACP.Directive.Helper

    test "unwraps the async {:command_result, ...} reply into {:ok, payload}" do
      {:ok, job_id} = InMemory.create_job("0xa", "0xb", 1_700_000_000)

      d =
        Directive.create_memo(
          job_id: job_id,
          content: "ack",
          memo_type: :message,
          next_phase: :negotiation
        )

      assert {:ok, "tx-" <> _} = Helper.execute_sync(d)
    end

    test "surfaces {:error, reason} when the contract client returns one" do
      d =
        Directive.create_memo(
          job_id: "ghost-job",
          content: "ack",
          memo_type: :message,
          next_phase: :negotiation
        )

      assert {:error, _reason} = Helper.execute_sync(d)
    end
  end
end
