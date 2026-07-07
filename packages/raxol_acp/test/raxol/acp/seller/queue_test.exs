defmodule Raxol.ACP.Seller.QueueTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.JobSession
  alias Raxol.ACP.Offering.Registry, as: OfferingRegistry
  alias Raxol.ACP.ProviderAdapter
  alias Raxol.ACP.Seller.Queue
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

    on_exit(fn ->
      Application.delete_env(:raxol_acp, :seller_provider_adapter)
      Application.delete_env(:raxol_acp, :seller_chain_id)
      Application.delete_env(:raxol_acp, :seller_acp_core_address)
      terminate_sessions()
    end)

    {:ok, adapter: adapter}
  end

  # -- helpers --

  defp terminate_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor), is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    :ok
  end

  defp attach_telemetry(events) do
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

  defp job_id, do: "job-#{System.unique_integer([:positive])}"

  defp offer(job_id, overrides \\ %{}) do
    Queue.dispatch(
      Map.merge(
        %{
          type: :job_offered,
          job_id: job_id,
          offering: "test.echo",
          request: %{"text" => "ping"},
          buyer: @buyer
        },
        overrides
      )
    )
  end

  defp wait_status(job_id, target, timeout_ms \\ 500) do
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

  # -- tests --

  describe ":job_offered dispatch" do
    setup do
      attach_telemetry([:dispatched, :dropped])
      {:ok, _spec} = EchoOffering.register()
      :ok
    end

    test "starts a provider JobSession, sets the budget on-chain, mirrors :budget_set", %{
      adapter: adapter
    } do
      jid = job_id()
      offer(jid)

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dispatched],
                      %{type: :job_offered}},
                     500

      :ok = wait_status(jid, :budget_set)

      assert [{@chain, [call]}] = ProviderAdapter.Mock.sent_calls(adapter)
      assert call.to == @core
    end
  end

  describe "drops" do
    setup do
      attach_telemetry([:dropped])
      :ok
    end

    test "unknown offering drops as :offering_not_registered" do
      offer(job_id(), %{offering: "nope.no.such"})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :job_offered, reason: :offering_not_registered}},
                     200
    end

    test ":payment_received for an unknown job drops as :job_not_running" do
      Queue.dispatch(%{type: :payment_received, job_id: "ghost", payload: %{}})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :payment_received, reason: :job_not_running}},
                     200
    end

    test ":approval_received for an unknown job drops as :job_not_running" do
      Queue.dispatch(%{type: :approval_received, job_id: "ghost", payload: %{}})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :approval_received, reason: :job_not_running}},
                     200
    end

    test "an unknown event type drops as :unknown_event" do
      Queue.dispatch(%{type: :nonsense, job_id: "x"})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :nonsense, reason: :unknown_event}},
                     200
    end

    test ":job_offered without an offering key drops as :malformed, and the Queue survives" do
      Queue.dispatch(%{type: :job_offered, job_id: "x"})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :job_offered, reason: :malformed}},
                     200

      # A malformed event didn't take the Queue down: a follow-up still processes.
      Queue.dispatch(%{type: :nonsense, job_id: "y"})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :nonsense, reason: :unknown_event}},
                     200
    end

    test "an event with no :type drops as :malformed instead of raising in the caller" do
      Queue.dispatch(%{job_id: "z"})

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{reason: :malformed}},
                     200
    end

    test ":job_offered drops as :no_provider_adapter when none is configured" do
      Application.delete_env(:raxol_acp, :seller_provider_adapter)
      {:ok, _spec} = EchoOffering.register()

      offer(job_id())

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :job_offered, reason: :no_provider_adapter}},
                     200
    end
  end

  describe "downstream errors are not swallowed" do
    setup do
      attach_telemetry([:dispatched, :dropped])
      {:ok, _spec} = EchoOffering.register()
      :ok
    end

    test "a failed on-chain write drops as {:handler_error, _}, not dispatched", %{
      adapter: adapter
    } do
      ProviderAdapter.Mock.set_send_calls_error(adapter, :rpc_down)

      offer(job_id())

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :job_offered, reason: {:handler_error, :rpc_down}}},
                     500
    end
  end

  describe "backpressure" do
    setup do
      attach_telemetry([:dispatched, :dropped])
      {:ok, _spec} = EchoOffering.register()

      prev = Application.get_env(:raxol_acp, :seller_max_active_jobs)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:raxol_acp, :seller_max_active_jobs, prev),
          else: Application.delete_env(:raxol_acp, :seller_max_active_jobs)
      end)

      :ok
    end

    test "rejects a second :job_offered once the active-session cap is reached" do
      Application.put_env(:raxol_acp, :seller_max_active_jobs, 1)

      job_a = job_id()
      job_b = job_id()

      offer(job_a)

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dispatched],
                      %{type: :job_offered, job_id: ^job_a}},
                     500

      :ok = wait_status(job_a, :budget_set)

      offer(job_b)

      assert_receive {:telemetry, [:raxol, :acp, :seller, :queue, :dropped],
                      %{type: :job_offered, job_id: ^job_b, reason: :at_capacity}},
                     500

      assert JobSession.Registry.whereis({@chain, job_b}) == :undefined
    end
  end
end
