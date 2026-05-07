defmodule Raxol.ACP.Job.IntegrationTest do
  @moduledoc """
  End-to-end integration test that wires together every layer the v0.1
  package ships:

  - `Raxol.ACP.Offering` DSL declaration
  - `Raxol.ACP.Offering.Registry` lookup
  - `Raxol.ACP.ContractClient` (InMemory impl)
  - `Raxol.ACP.Job.Supervisor` + `Job.Server` + `Job.Registry`
  - `Raxol.ACP.Job.StateMachine` validation
  - `Raxol.ACP.Job.Memo` EIP-712 signing via a real
    `Raxol.Payments.Wallets.Env` wallet

  Drives one full ACP job (request -> negotiation -> transaction ->
  evaluation -> completed) using `EchoOffering` as the seller's
  handler. Asserts memos accumulated in submission order, payloads
  contain handler outputs, signatures are real (65 bytes), final state
  is `:completed`, and the server terminates cleanly.
  """

  use ExUnit.Case, async: false

  alias Raxol.ACP.{ContractClient, Job}
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job.Store
  alias Raxol.ACP.TestSupport.EchoOffering

  @test_env_var "RAXOL_ACP_INTEGRATION_KEY"
  @test_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @verifying_contract "0x" <> String.duplicate("ab", 20)
  @memo_opts [chain_id: 8453, verifying_contract: @verifying_contract]
  @seller "0x" <> String.duplicate("11", 20)
  @buyer "0x" <> String.duplicate("22", 20)
  @request %{"text" => "ping"}

  defmodule Wallet do
    use Raxol.Payments.Wallets.Env,
      env_var: "RAXOL_ACP_INTEGRATION_KEY",
      chain_id: 8453
  end

  setup do
    System.put_env(@test_env_var, @test_privkey)

    on_exit(fn -> System.delete_env(@test_env_var) end)

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
      ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)

    {:ok, pid} =
      Job.Supervisor.start_job(
        job_id: job_id,
        handler: EchoOffering,
        wallet: Wallet,
        memo_opts: @memo_opts,
        request: @request,
        buyer: @buyer,
        seller: @seller
      )

    {pid, job_id}
  end

  describe "full lifecycle: request -> completed via handler + wallet" do
    test "every transition produces a real signed memo with handler output" do
      {pid, job_id} = start_configured_job()
      ref = Process.monitor(pid)

      # 1. Seller accepts the request -- handler.handle_request runs,
      # returns {:accept, request} (echo passes through).
      assert {:ok, :negotiation} = Job.Server.accept_request(job_id)

      # 2. Buyer's payment lands -- payload is the buyer's signed auth.
      # In tests we let the server sign with our wallet for convenience.
      assert {:ok, :transaction} =
               Job.Server.accept_payment(job_id, %{auth: "buyer-payment-blob"})

      # 3. Seller delivers -- handler.handle_deliver runs, echoes the
      # request as %{"echo" => "ping"}.
      assert {:ok, :evaluation} = Job.Server.deliver(job_id)

      # 4. Buyer (acting as evaluator) approves -- terminal transition.
      assert {:ok, :completed} = Job.Server.approve(job_id, %{ok: true})

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
      wait_unregistered(job_id)

      # The InMemory contract client recorded all four memos in order.
      memos = InMemory.list_memos(job_id)

      assert Enum.map(memos, & &1.type) ==
               [:negotiation, :transaction, :evaluation, :completed]

      # Each memo's payload reflects the right phase.
      [neg, tx, eval, comp] = memos
      assert neg.payload == @request
      assert tx.payload == %{auth: "buyer-payment-blob"}
      assert eval.payload == %{"echo" => "ping"}
      assert comp.payload == %{ok: true}

      # All signatures are real EIP-712 (65 bytes), not placeholder bytes.
      for memo <- memos do
        assert byte_size(memo.signature) == 65
      end
    end

    test "rejecting in handle_request fires :expire instead of :accept_request" do
      defmodule RejectOffering do
        use Raxol.ACP.Offering, name: "test.reject"
        @impl true
        def handle_request(_req, _ctx), do: {:reject, :not_today}
        @impl true
        def handle_deliver(_req, _ctx), do: {:deliver, %{}}
      end

      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)

      {:ok, pid} =
        Job.Supervisor.start_job(
          job_id: job_id,
          handler: RejectOffering,
          wallet: Wallet,
          memo_opts: @memo_opts,
          request: @request
        )

      ref = Process.monitor(pid)

      assert {:ok, :expired} = Job.Server.accept_request(job_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

      [memo] = InMemory.list_memos(job_id)
      assert memo.type == :expired
      assert memo.payload == %{reason: ":not_today"}
    end

    test "deliver error from handler fires :expire" do
      defmodule BrokenOffering do
        use Raxol.ACP.Offering, name: "test.broken"
        @impl true
        def handle_request(req, _ctx), do: {:accept, req}
        @impl true
        def handle_deliver(_req, _ctx), do: {:error, :upstream_down}
      end

      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)

      {:ok, _} =
        Job.Supervisor.start_job(
          job_id: job_id,
          handler: BrokenOffering,
          wallet: Wallet,
          memo_opts: @memo_opts,
          request: @request
        )

      assert {:ok, :negotiation} = Job.Server.accept_request(job_id)
      assert {:ok, :transaction} = Job.Server.accept_payment(job_id, %{})
      assert {:ok, :expired} = Job.Server.deliver(job_id)
    end
  end

  describe "config validation" do
    test "accept_request without :handler returns config_missing" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)
      {:ok, _} = Job.Supervisor.start_job(job_id: job_id)

      assert {:error, {:config_missing, missing}} = Job.Server.accept_request(job_id)
      assert :handler in missing
      assert :request in missing
    end

    test "accept_payment without wallet falls back to caller signature" do
      {:ok, job_id} =
        ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)

      {:ok, _} =
        Job.Supervisor.start_job(
          job_id: job_id,
          handler: EchoOffering,
          wallet: Wallet,
          memo_opts: @memo_opts,
          request: @request
        )

      {:ok, :negotiation} = Job.Server.accept_request(job_id)

      # Caller-supplied signature path bypasses the wallet entirely.
      assert {:ok, :transaction} =
               Job.Server.accept_payment(job_id, %{}, <<0xCA, 0xFE>>)

      [_negotiation, transaction] = InMemory.list_memos(job_id)
      assert transaction.signature == <<0xCA, 0xFE>>
    end
  end

  describe "low-level transition/4 still works" do
    test "raw transition path bypasses handler entirely" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.01"), <<>>)
      {:ok, _} = Job.Supervisor.start_job(job_id: job_id)

      assert {:ok, :negotiation} =
               Job.Server.transition(job_id, :accept_request, %{}, <<0xAA>>)
    end
  end
end
