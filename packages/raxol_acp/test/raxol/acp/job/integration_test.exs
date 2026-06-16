defmodule Raxol.ACP.Job.IntegrationTest do
  @moduledoc """
  End-to-end integration test that wires together every layer the v0.1
  package ships:

  - `Raxol.ACP.Offering` DSL declaration
  - `Raxol.ACP.Offering.Registry` lookup
  - `Raxol.ACP.ContractClient` (InMemory impl)
  - `Raxol.ACP.Job.Supervisor` + `Job.Server` + `Job.Registry`
  - `Raxol.ACP.Job.StateMachine` validation
  - `Raxol.ACP.ContractClient.create_memo/5` on every transition

  Drives one full ACP job (request -> negotiation -> transaction ->
  evaluation -> completed) using `EchoOffering` as the seller's
  handler. Asserts memos accumulated in submission order, payloads
  contain handler outputs, final state is `:completed`, and the
  server terminates cleanly.
  """

  use ExUnit.Case, async: false

  import Raxol.ACP.TestSupport.WorkflowSetup

  alias Raxol.ACP.{ContractClient, Job}
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job.Store
  alias Raxol.ACP.TestSupport.EchoOffering

  @seller "0x" <> String.duplicate("11", 20)
  @buyer "0x" <> String.duplicate("22", 20)
  @request %{"text" => "ping"}

  setup :with_isolated_workflow_saver

  setup do
    # Clear any leftover Job.Server processes so synthetic "job-N" ids
    # from InMemory's counter don't collide with old registrations.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Job.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Job.Supervisor, pid)
    end

    InMemory.reset()
    Store.clear()
    :ok
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

  defp start_configured_job do
    {:ok, job_id} =
      ContractClient.create_job(@seller, @seller, 9_999_999_999)

    {:ok, pid} =
      Job.Supervisor.start_job(
        job_id: job_id,
        handler: EchoOffering,
        request: @request,
        buyer: @buyer,
        seller: @seller
      )

    {pid, job_id}
  end

  describe "full lifecycle: request -> completed via handler" do
    test "every transition produces an on-chain memo with handler output" do
      {pid, job_id} = start_configured_job()
      ref = Process.monitor(pid)

      # 1. Seller accepts the request -- handler.handle_request runs,
      # returns {:accept, request} (echo passes through).
      assert {:ok, :negotiation} = Job.Server.accept_request(job_id)

      # 2. Buyer's payment lands -- payload is the buyer's signed auth.
      buyer_sig = <<0xCA, 0xFE>>

      assert {:ok, :transaction} =
               Job.Server.accept_payment(job_id, %{auth: "buyer-payment-blob"}, buyer_sig)

      # 3. Seller delivers -- handler.handle_deliver runs, echoes the
      # request as %{"echo" => "ping"}.
      assert {:ok, :evaluation} = Job.Server.deliver(job_id)

      # 4. Buyer (acting as evaluator) approves -- terminal transition.
      approve_sig = <<0xBE, 0xEF>>
      assert {:ok, :completed} = Job.Server.approve(job_id, %{ok: true}, approve_sig)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
      wait_unregistered(job_id)

      # The InMemory contract client recorded all four memos in order.
      memos = InMemory.list_memos(job_id)

      assert Enum.map(memos, & &1.next_phase) ==
               [:negotiation, :transaction, :evaluation, :completed]

      # Payment and approval transitions use :txhash; the rest are :message.
      assert Enum.map(memos, & &1.memo_type) ==
               [:message, :txhash, :message, :txhash]

      # Each memo's content reflects the right phase (JSON-encoded payload).
      [neg, tx, eval, comp] = memos
      assert Jason.decode!(neg.content) == @request
      assert Jason.decode!(tx.content) == %{"auth" => "buyer-payment-blob"}
      assert Jason.decode!(eval.content) == %{"echo" => "ping"}
      assert Jason.decode!(comp.content) == %{"ok" => true}
    end

    test "rejecting in handle_request fires :expire instead of :accept_request" do
      defmodule RejectOffering do
        use Raxol.ACP.Offering, name: "test.reject"
        @impl true
        def handle_request(_req, _ctx), do: {:reject, :not_today}
        @impl true
        def handle_deliver(_req, _ctx), do: {:deliver, %{}}
      end

      {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)

      {:ok, pid} =
        Job.Supervisor.start_job(
          job_id: job_id,
          handler: RejectOffering,
          request: @request
        )

      ref = Process.monitor(pid)

      assert {:ok, :expired} = Job.Server.accept_request(job_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

      [memo] = InMemory.list_memos(job_id)
      assert memo.next_phase == :expired
      assert Jason.decode!(memo.content) == %{"reason" => ":not_today"}
    end

    test "deliver error from handler fires :expire" do
      defmodule BrokenOffering do
        use Raxol.ACP.Offering, name: "test.broken"
        @impl true
        def handle_request(req, _ctx), do: {:accept, req}
        @impl true
        def handle_deliver(_req, _ctx), do: {:error, :upstream_down}
      end

      {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)

      {:ok, _} =
        Job.Supervisor.start_job(
          job_id: job_id,
          handler: BrokenOffering,
          request: @request
        )

      assert {:ok, :negotiation} = Job.Server.accept_request(job_id)
      assert {:ok, :transaction} = Job.Server.accept_payment(job_id, %{})
      assert {:ok, :expired} = Job.Server.deliver(job_id)
    end
  end

  describe "config validation" do
    test "accept_request without :handler returns config_missing" do
      {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)
      {:ok, _} = Job.Supervisor.start_job(job_id: job_id)

      assert {:error, {:config_missing, missing}} = Job.Server.accept_request(job_id)
      assert :handler in missing
      assert :request in missing
    end

    test "buyer signature is preserved in the local memo log" do
      {:ok, job_id} =
        ContractClient.create_job(@seller, @seller, 9_999_999_999)

      {:ok, _} =
        Job.Supervisor.start_job(
          job_id: job_id,
          handler: EchoOffering,
          request: @request
        )

      {:ok, :negotiation} = Job.Server.accept_request(job_id)

      assert {:ok, :transaction} =
               Job.Server.accept_payment(job_id, %{}, <<0xCA, 0xFE>>)

      [_negotiation, transaction] = Job.Server.memos(job_id)
      assert transaction.signature == <<0xCA, 0xFE>>
    end
  end

  describe "low-level transition/4 still works" do
    test "raw transition path bypasses handler entirely" do
      {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)
      {:ok, _} = Job.Supervisor.start_job(job_id: job_id)

      assert {:ok, :negotiation} =
               Job.Server.transition(job_id, :accept_request, %{}, <<0xAA>>)
    end
  end
end
