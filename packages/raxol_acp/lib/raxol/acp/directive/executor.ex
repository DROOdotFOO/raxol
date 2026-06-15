defmodule Raxol.ACP.Directive.Helper do
  @moduledoc false

  @doc """
  Run `fun/0` in a Task, route success to `{:command_result, {success_tag, payload}}`,
  errors to `{:command_result, {error_tag, reason}}`, and any raise to
  `{:command_result, {error_tag, {:exception, message}}}`.
  """
  @spec run_async(pid(), atom(), atom(), (-> {:ok, term()} | {:error, term()})) :: {:ok, pid()}
  def run_async(pid, success_tag, error_tag, fun) do
    Task.start(fn ->
      try do
        case fun.() do
          {:ok, payload} ->
            send(pid, {:command_result, {success_tag, payload}})

          {:error, reason} ->
            send(pid, {:command_result, {error_tag, reason}})

          other ->
            send(pid, {:command_result, {success_tag, other}})
        end
      rescue
        e ->
          send(pid, {:command_result, {error_tag, {:exception, Exception.message(e)}}})
      end
    end)
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.ACP.Directive.CreateJob do
  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Directive.{CreateJob, Helper}

  def execute(%CreateJob{provider: provider, evaluator: evaluator, expired_at: expired_at}, ctx) do
    Helper.run_async(ctx.pid, :acp_create_job_result, :acp_create_job_error, fn ->
      ContractClient.create_job(provider, evaluator, expired_at)
    end)
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.ACP.Directive.SetBudget do
  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Directive.{Helper, SetBudget}

  def execute(%SetBudget{job_id: job_id, amount: amount}, ctx) do
    Helper.run_async(ctx.pid, :acp_set_budget_result, :acp_set_budget_error, fn ->
      ContractClient.set_budget(job_id, amount)
    end)
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor,
  for: Raxol.ACP.Directive.SetBudgetWithPaymentToken do
  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Directive.{Helper, SetBudgetWithPaymentToken}

  def execute(%SetBudgetWithPaymentToken{job_id: job_id, amount: amount, token: token}, ctx) do
    Helper.run_async(
      ctx.pid,
      :acp_set_budget_with_payment_token_result,
      :acp_set_budget_with_payment_token_error,
      fn -> ContractClient.set_budget_with_payment_token(job_id, amount, token) end
    )
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.ACP.Directive.CreateMemo do
  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Directive.{CreateMemo, Helper}

  def execute(%CreateMemo{} = d, ctx) do
    Helper.run_async(ctx.pid, :acp_create_memo_result, :acp_create_memo_error, fn ->
      ContractClient.create_memo(d.job_id, d.content, d.memo_type, d.is_secured, d.next_phase)
    end)
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.ACP.Directive.CreatePayableMemo do
  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Directive.{CreatePayableMemo, Helper}

  def execute(%CreatePayableMemo{job_id: job_id, content: content, opts: opts}, ctx) do
    Helper.run_async(
      ctx.pid,
      :acp_create_payable_memo_result,
      :acp_create_payable_memo_error,
      fn -> ContractClient.create_payable_memo(job_id, content, opts) end
    )
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.ACP.Directive.SignMemo do
  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Directive.{Helper, SignMemo}

  def execute(%SignMemo{memo_id: memo_id, approved: approved, reason: reason}, ctx) do
    Helper.run_async(ctx.pid, :acp_sign_memo_result, :acp_sign_memo_error, fn ->
      ContractClient.sign_memo(memo_id, approved, reason)
    end)
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.ACP.Directive.ClaimBudget do
  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Directive.{ClaimBudget, Helper}

  def execute(%ClaimBudget{job_id: job_id}, ctx) do
    Helper.run_async(ctx.pid, :acp_claim_budget_result, :acp_claim_budget_error, fn ->
      ContractClient.claim_budget(job_id)
    end)
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.ACP.Directive.ConfirmX402Payment do
  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Directive.{ConfirmX402Payment, Helper}

  def execute(%ConfirmX402Payment{job_id: job_id}, ctx) do
    Helper.run_async(ctx.pid, :acp_confirm_x402_result, :acp_confirm_x402_error, fn ->
      ContractClient.confirm_x402_payment_received(job_id)
    end)
  end
end
