defmodule Raxol.ACP.Seller.IntegrationTest do
  @moduledoc """
  End-to-end seller test: events injected through `Backend.InMemory`
  drive a job from `:request` through `:completed` with all four memos
  signed by a real `Raxol.Payments.Wallets.Env` wallet and persisted to
  the Store.

  Exercises the full path:

      InMemory.publish/1
        -> Runtime ({:acp_event, _})
        -> Queue.dispatch/1
        -> Job.Supervisor.start_job/1 (or routing to existing pid)
        -> Job.Server (handler invocation, wallet signing, ContractClient, Store)
  """

  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory, as: ContractInMem
  alias Raxol.ACP.Job
  alias Raxol.ACP.Job.Store
  alias Raxol.ACP.Offering.Registry, as: OfferingRegistry
  alias Raxol.ACP.Seller.Backend.InMemory, as: BackendInMem
  alias Raxol.ACP.TestSupport.{EchoOffering, SellerHelper}

  @env_var "RAXOL_ACP_SELLER_INTEGRATION_KEY"
  @privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @memo_opts [chain_id: 8453, verifying_contract: "0x" <> String.duplicate("ab", 20)]
  @seller "0x" <> String.duplicate("11", 20)
  @buyer "0x" <> String.duplicate("22", 20)

  defmodule Wallet do
    use Raxol.Payments.Wallets.Env,
      env_var: "RAXOL_ACP_SELLER_INTEGRATION_KEY",
      chain_id: 8453
  end

  setup do
    System.put_env(@env_var, @privkey)
    OfferingRegistry.clear()
    ContractInMem.reset()
    Store.clear()

    on_exit(fn -> System.delete_env(@env_var) end)

    :ok =
      SellerHelper.reset_seller(wallet: Wallet, memo_opts: @memo_opts, seller_address: @seller)

    {:ok, _spec} = EchoOffering.register()
    :ok
  end

  defp wait_for_state(job_id, target, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_state(job_id, target, deadline)
  end

  defp do_wait_for_state(job_id, target, deadline) do
    case current_state(job_id) do
      ^target ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          do_wait_for_state(job_id, target, deadline)
        else
          flunk("Job #{job_id} never reached #{target}; saw #{inspect(current_state(job_id))}")
        end
    end
  end

  defp current_state(job_id) do
    case Job.Registry.whereis(job_id) do
      :undefined ->
        from_store(job_id)

      pid ->
        try do
          Job.Server.current_state(pid)
        catch
          # Server is in the middle of terminating; fall back to the
          # last persisted state, which is the same answer.
          :exit, _ -> from_store(job_id)
        end
    end
  end

  defp from_store(job_id) do
    case Store.load(job_id) do
      {:ok, %{state: state}} -> state
      :error -> :no_record
    end
  end

  defp wait_unregistered(job_id, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_unregistered(job_id, deadline)
  end

  defp do_wait_unregistered(job_id, deadline) do
    case Job.Registry.whereis(job_id) do
      :undefined ->
        :ok

      _pid ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          do_wait_unregistered(job_id, deadline)
        else
          flunk("Job.Registry still has #{job_id}")
        end
    end
  end

  test "full lifecycle: events drive the job from :request to :completed" do
    {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.50"), <<>>)

    # 1. Buyer offers a job to our seller.
    BackendInMem.publish(%{
      type: :job_offered,
      job_id: job_id,
      offering: "test.echo",
      request: %{"text" => "ping"},
      buyer: @buyer
    })

    :ok = wait_for_state(job_id, :negotiation)

    # 2. Buyer pays. The Queue routes the event to our running Job.Server,
    #    advancing to :transaction.
    BackendInMem.publish(%{
      type: :payment_received,
      job_id: job_id,
      payload: %{auth: "buyer-payment-blob"}
    })

    :ok = wait_for_state(job_id, :transaction)

    # 3. The handler decides delivery timing. EchoOffering's handle_deliver
    #    simply echoes the request, so we trigger it directly here. This is
    #    the design: the Queue does NOT auto-deliver (handlers control
    #    delivery, see Queue moduledoc).
    assert {:ok, :evaluation} = Job.Server.deliver(job_id)

    # 4. Buyer (or evaluator) approves. Terminal transition; Job.Server
    #    stops with :normal.
    BackendInMem.publish(%{
      type: :approval_received,
      job_id: job_id,
      payload: %{ok: true}
    })

    :ok = wait_for_state(job_id, :completed)
    :ok = wait_unregistered(job_id)

    # All four memos are persisted, in order, with real EIP-712 sigs.
    assert {:ok, %{memos: memos, state: :completed}} = Store.load(job_id)
    assert Enum.map(memos, & &1.type) == [:negotiation, :transaction, :evaluation, :completed]

    assert Enum.map(memos, & &1.payload) == [
             %{"text" => "ping"},
             %{auth: "buyer-payment-blob"},
             %{"echo" => "ping"},
             %{ok: true}
           ]

    for memo <- memos, do: assert(byte_size(memo.signature) == 65)

    # And the chain-side InMemory contract client recorded matching memos.
    assert Enum.map(ContractInMem.list_memos(job_id), & &1.type) ==
             [:negotiation, :transaction, :evaluation, :completed]
  end

  test "expiration event drives a non-terminal job to :expired" do
    {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.10"), <<>>)

    BackendInMem.publish(%{
      type: :job_offered,
      job_id: job_id,
      offering: "test.echo",
      request: %{"text" => "ping"},
      buyer: @buyer
    })

    :ok = wait_for_state(job_id, :negotiation)

    BackendInMem.publish(%{type: :job_expired, job_id: job_id, reason: "sla_breach"})

    :ok = wait_for_state(job_id, :expired)
    :ok = wait_unregistered(job_id)

    assert {:ok, %{state: :expired, memos: [_negotiation, expire]}} = Store.load(job_id)
    assert expire.type == :expired
  end
end
