defmodule Raxol.ACP.Seller.QueueTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job
  alias Raxol.ACP.Job.Store
  alias Raxol.ACP.Offering.Registry, as: OfferingRegistry
  alias Raxol.ACP.Seller.Queue
  alias Raxol.ACP.TestSupport.{EchoOffering, SellerHelper}

  @env_var "RAXOL_ACP_QUEUE_TEST_KEY"
  @privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @memo_opts [chain_id: 8453, verifying_contract: "0x" <> String.duplicate("ab", 20)]
  @seller "0x" <> String.duplicate("11", 20)
  @buyer "0x" <> String.duplicate("22", 20)

  defmodule Wallet do
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_ACP_QUEUE_TEST_KEY", chain_id: 8453
  end

  setup do
    System.put_env(@env_var, @privkey)
    OfferingRegistry.clear()
    InMemory.reset()
    Store.clear()
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  defp attach_telemetry(events) when is_list(events) do
    handler_id = "queue-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      Enum.map(events, &[:raxol, :acp, :seller, :queue, &1]),
      fn event, _measurements, metadata, _ -> send(test_pid, {:telemetry, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defp wait_for_state(job_id, target, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_state(job_id, target, deadline)
  end

  defp do_wait_for_state(job_id, target, deadline) do
    case safe_state(job_id) do
      ^target ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          do_wait_for_state(job_id, target, deadline)
        else
          flunk("Job #{job_id} never reached #{target}; saw #{inspect(safe_state(job_id))}")
        end
    end
  end

  defp safe_state(job_id) do
    case Job.Registry.whereis(job_id) do
      :undefined ->
        from_store(job_id)

      pid ->
        try do
          Job.Server.current_state(pid)
        catch
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

  describe "hybrid wallet resolution: defaults from config" do
    setup do
      :ok =
        SellerHelper.reset_seller(wallet: Wallet, memo_opts: @memo_opts, seller_address: @seller)

      :ok = attach_telemetry([:dispatched, :dropped])
      {:ok, _spec} = EchoOffering.register()
      :ok
    end

    test ":job_offered uses Queue defaults when the spec has no override" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)

      Queue.dispatch(%{
        type: :job_offered,
        job_id: job_id,
        offering: "test.echo",
        request: %{"text" => "ping"},
        buyer: @buyer
      })

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dispatched],
                      %{type: :job_offered}},
                     500

      :ok = wait_for_state(job_id, :negotiation)

      assert {:ok, %{state: :negotiation, memos: [memo]}} = Store.load(job_id)
      assert memo.type == :negotiation
      assert byte_size(memo.signature) == 65
    end
  end

  describe "hybrid wallet resolution: per-offering override beats default" do
    defmodule OverrideWallet do
      use Raxol.Payments.Wallets.Env, env_var: "RAXOL_ACP_QUEUE_TEST_KEY", chain_id: 1
    end

    defmodule OverrideOffering do
      use Raxol.ACP.Offering,
        name: "test.override",
        wallet: OverrideWallet,
        memo_opts: [chain_id: 1, verifying_contract: "0x" <> String.duplicate("cd", 20)]

      @impl Raxol.ACP.Offering.Handler
      def handle_request(req, _ctx), do: {:accept, req}
      @impl Raxol.ACP.Offering.Handler
      def handle_deliver(req, _ctx), do: {:deliver, req}
    end

    setup do
      :ok =
        SellerHelper.reset_seller(
          wallet: Wallet,
          memo_opts: @memo_opts,
          seller_address: @seller
        )

      :ok = attach_telemetry([:dispatched])
      {:ok, _} = OverrideOffering.register()
      :ok
    end

    test "the spec's wallet+memo_opts replace the Queue default" do
      assert OverrideOffering.spec().wallet == OverrideWallet

      assert OverrideOffering.spec().memo_opts == [
               chain_id: 1,
               verifying_contract: "0x" <> String.duplicate("cd", 20)
             ]

      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)

      Queue.dispatch(%{
        type: :job_offered,
        job_id: job_id,
        offering: "test.override",
        request: %{"x" => 1},
        buyer: @buyer
      })

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dispatched],
                      %{offering: "test.override"}},
                     500

      :ok = wait_for_state(job_id, :negotiation)
    end
  end

  describe "missing wallet" do
    setup do
      :ok = SellerHelper.reset_seller([])
      :ok = attach_telemetry([:dropped])
      {:ok, _spec} = EchoOffering.register()
      :ok
    end

    test "drops :job_offered when neither default nor spec provides a wallet" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)

      Queue.dispatch(%{
        type: :job_offered,
        job_id: job_id,
        offering: "test.echo",
        request: %{"text" => "ping"},
        buyer: @buyer
      })

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :job_offered, reason: :wallet_unconfigured}},
                     200

      assert Job.Registry.whereis(job_id) == :undefined
      assert :error = Store.load(job_id)
    end
  end

  describe "unknown offering" do
    setup do
      :ok =
        SellerHelper.reset_seller(wallet: Wallet, memo_opts: @memo_opts, seller_address: @seller)

      :ok = attach_telemetry([:dropped])
      :ok
    end

    test "drops :job_offered when the offering is not registered" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)

      Queue.dispatch(%{
        type: :job_offered,
        job_id: job_id,
        offering: "nope.no.such",
        request: %{},
        buyer: @buyer
      })

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :job_offered, reason: :offering_not_registered}},
                     200
    end
  end

  describe "events for non-running jobs" do
    setup do
      :ok =
        SellerHelper.reset_seller(wallet: Wallet, memo_opts: @memo_opts, seller_address: @seller)

      :ok = attach_telemetry([:dropped])
      :ok
    end

    test ":payment_received drops with :job_not_running for unknown job_id" do
      Queue.dispatch(%{type: :payment_received, job_id: "ghost", payload: %{}})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :payment_received, reason: :job_not_running}},
                     200
    end

    test ":approval_received drops with :job_not_running for unknown job_id" do
      Queue.dispatch(%{type: :approval_received, job_id: "ghost", payload: %{}})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :approval_received, reason: :job_not_running}},
                     200
    end
  end

  describe "unknown event types" do
    setup do
      :ok = SellerHelper.reset_seller([])
      :ok = attach_telemetry([:dropped])
      :ok
    end

    test "are dropped with :unknown_event reason" do
      Queue.dispatch(%{type: :nonsense, job_id: "x"})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :nonsense, reason: :unknown_event}},
                     200
    end
  end
end
