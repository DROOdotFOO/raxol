defmodule Raxol.ACP.Seller.IntegrationTest do
  @moduledoc """
  End-to-end seller test: events injected through `Backend.InMemory` drive a job
  from `:open` through `:completed` as the provider, writing the hook calls
  on-chain via a `ProviderAdapter.Mock` (the only fake -- it stands in for the
  bundler/RPC so CI doesn't hit a real chain) and mirroring status into the job's
  `JobSession`.

      InMemory.publish/1
        -> Runtime ({:acp_event, _})
        -> Queue.dispatch/1
        -> JobSession.Provider (handler + HookClient + JobSession)
  """

  use ExUnit.Case, async: false

  alias Raxol.ACP.JobSession
  alias Raxol.ACP.Offering.Registry, as: OfferingRegistry
  alias Raxol.ACP.ProviderAdapter
  alias Raxol.ACP.Seller.Backend.InMemory, as: BackendInMem
  alias Raxol.ACP.TestSupport.{EchoOffering, SellerHelper}

  @seller "0x" <> String.duplicate("11", 20)
  @buyer "0x" <> String.duplicate("22", 20)
  @chain 8453
  @core "0x238E541BfefD82238730D00a2208E5497F1832E0"

  setup do
    terminate_sessions()
    OfferingRegistry.clear()

    adapter = ProviderAdapter.Mock.new()
    :ok = SellerHelper.reset_seller(seller_address: @seller)
    Application.put_env(:raxol_acp, :seller_provider_adapter, adapter)
    Application.put_env(:raxol_acp, :seller_chain_id, @chain)
    Application.put_env(:raxol_acp, :seller_acp_core_address, @core)
    {:ok, _spec} = EchoOffering.register()

    on_exit(fn ->
      Application.delete_env(:raxol_acp, :seller_provider_adapter)
      Application.delete_env(:raxol_acp, :seller_chain_id)
      Application.delete_env(:raxol_acp, :seller_acp_core_address)
      terminate_sessions()
    end)

    {:ok, adapter: adapter}
  end

  defp terminate_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor), is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    :ok
  end

  defp job_id, do: "job-#{System.unique_integer([:positive])}"

  defp wait_status(job_id, target, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_status(job_id, target, deadline)
  end

  defp do_wait_status(job_id, target, deadline) do
    case status(job_id) do
      ^target ->
        :ok

      other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          do_wait_status(job_id, target, deadline)
        else
          flunk("job #{job_id} never reached #{target}; saw #{inspect(other)}")
        end
    end
  end

  defp status(job_id) do
    case JobSession.Registry.whereis({@chain, job_id}) do
      :undefined ->
        :gone

      pid ->
        try do
          JobSession.status(pid)
        catch
          :exit, _ -> :gone
        end
    end
  end

  defp selectors_sent(adapter) do
    for {@chain, [call]} <- ProviderAdapter.Mock.sent_calls(adapter),
        do: binary_part(call.data, 0, 4)
  end

  test "backend events drive a job from offer to completion via hook calls", %{adapter: adapter} do
    jid = job_id()

    # 1. Buyer offers -> provider sets the budget on-chain -> :budget_set.
    BackendInMem.publish(%{
      type: :job_offered,
      job_id: jid,
      offering: "test.echo",
      request: %{"text" => "ping"},
      buyer: @buyer
    })

    :ok = wait_status(jid, :budget_set)

    # 2. Buyer funds -> provider delivers (submit) -> :submitted.
    BackendInMem.publish(%{type: :payment_received, job_id: jid, payload: %{auth: "blob"}})
    :ok = wait_status(jid, :submitted)

    # 3. External evaluator approves -> :completed (terminal; session stops).
    BackendInMem.publish(%{type: :approval_received, job_id: jid, payload: %{ok: true}})
    :ok = wait_status(jid, :gone)

    # We wrote exactly setBudget then submit; complete was the evaluator's, not ours.
    assert selectors_sent(adapter) == [
             Raxol.ACP.ABI.function_selector("setBudget(uint256,uint256,bytes)"),
             Raxol.ACP.ABI.function_selector("submit(uint256,bytes32,bytes)")
           ]
  end

  test "an expiration event drives a non-terminal job to :expired", %{adapter: adapter} do
    jid = job_id()

    BackendInMem.publish(%{
      type: :job_offered,
      job_id: jid,
      offering: "test.echo",
      request: %{"text" => "ping"},
      buyer: @buyer
    })

    :ok = wait_status(jid, :budget_set)

    BackendInMem.publish(%{type: :job_expired, job_id: jid, reason: "sla_breach"})
    :ok = wait_status(jid, :gone)

    # Only the setBudget was written; expiry is a status mirror, no on-chain call.
    assert selectors_sent(adapter) == [
             Raxol.ACP.ABI.function_selector("setBudget(uint256,uint256,bytes)")
           ]
  end
end
