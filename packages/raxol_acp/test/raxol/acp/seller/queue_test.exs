defmodule Raxol.ACP.Seller.QueueTest do
  use ExUnit.Case, async: false

  import Raxol.ACP.TestSupport.WorkflowSetup

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job
  alias Raxol.ACP.Job.Store
  alias Raxol.ACP.Offering.Registry, as: OfferingRegistry
  alias Raxol.ACP.Seller.Queue
  alias Raxol.ACP.TestSupport.{EchoOffering, SellerHelper}

  @seller "0x" <> String.duplicate("11", 20)
  @buyer "0x" <> String.duplicate("22", 20)

  setup :with_isolated_workflow_saver

  setup do
    OfferingRegistry.clear()
    InMemory.reset()
    Store.clear()
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

  describe ":job_offered dispatch" do
    setup do
      :ok = SellerHelper.reset_seller(seller_address: @seller)
      :ok = attach_telemetry([:dispatched, :dropped])
      {:ok, _spec} = EchoOffering.register()
      :ok
    end

    test "starts a Job.Server, accepts the request, and persists the negotiation memo" do
      {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)

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
      assert memo.next_phase == :negotiation
      assert memo.memo_type == :message
    end
  end

  describe "unknown offering" do
    setup do
      :ok = SellerHelper.reset_seller(seller_address: @seller)
      :ok = attach_telemetry([:dropped])
      :ok
    end

    test "drops :job_offered when the offering is not registered" do
      {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)

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
      :ok = SellerHelper.reset_seller(seller_address: @seller)
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
