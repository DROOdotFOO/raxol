defmodule Raxol.ACP.JobSession.ProviderTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.{ABI, AssetToken, JobSession, ProviderAdapter}
  alias Raxol.ACP.JobSession.Provider

  @core "0x238E541BfefD82238730D00a2208E5497F1832E0"
  @chain 8453

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor), is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    :ok
  end

  defmodule AcceptHandler do
    @behaviour Raxol.ACP.Offering.Handler
    @impl true
    def handle_request(req, _ctx), do: {:accept, %{ack: req}}
    @impl true
    def handle_deliver(_req, _ctx), do: {:deliver, %{result: "done"}}
    @impl true
    def handle_evaluate(_deliverable, _ctx), do: {:approve, %{}}
  end

  defmodule RejectHandler do
    @behaviour Raxol.ACP.Offering.Handler
    @impl true
    def handle_request(_req, _ctx), do: {:reject, :not_for_me}
    @impl true
    def handle_deliver(_req, _ctx), do: {:error, :cannot_build}
    @impl true
    def handle_evaluate(_deliverable, _ctx), do: {:reject, :bad_work}
  end

  defmodule NoEvaluateHandler do
    @behaviour Raxol.ACP.Offering.Handler
    @impl true
    def handle_request(req, _ctx), do: {:accept, %{ack: req}}
    @impl true
    def handle_deliver(_req, _ctx), do: {:deliver, %{result: "done"}}
  end

  defp start_session(status) do
    job_id = "job-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      JobSession.Supervisor.start_session(
        chain_id: @chain,
        job_id: job_id,
        role: :provider,
        initial_status: status
      )

    pid
  end

  defp provider(session, handler, adapter) do
    Provider.new(
      session: session,
      handler: handler,
      adapter: adapter,
      chain_id: @chain,
      acp_core_address: @core,
      job_id: 42,
      buyer: "0xbuyer",
      seller: "0xseller"
    )
  end

  defp assert_one_call(adapter, signature) do
    assert [{@chain, [call]}] = ProviderAdapter.Mock.sent_calls(adapter)
    assert call.to == @core
    selector = ABI.function_selector(signature)
    assert <<^selector::binary-size(4), _rest::binary>> = call.data
  end

  describe "accept_request/3" do
    test "accept: writes setBudget on-chain and mirrors :budget_set" do
      adapter = ProviderAdapter.Mock.new()
      session = start_session(:open)
      p = provider(session, AcceptHandler, adapter)

      assert {:ok, %{status: :budget_set, tx_hash: tx, response: %{ack: %{req: 1}}}} =
               Provider.accept_request(p, %{req: 1}, AssetToken.usdc(0.25, @chain))

      assert is_binary(tx)
      assert JobSession.status(session) == :budget_set
      assert_one_call(adapter, "setBudget(uint256,uint256,bytes)")
    end

    test "reject: no on-chain write, session unchanged" do
      adapter = ProviderAdapter.Mock.new()
      session = start_session(:open)
      p = provider(session, RejectHandler, adapter)

      assert {:rejected, :not_for_me} =
               Provider.accept_request(p, %{req: 1}, AssetToken.usdc(0.25, @chain))

      assert JobSession.status(session) == :open
      assert ProviderAdapter.Mock.sent_calls(adapter) == []
    end

    test "does not advance the session when the chain write fails" do
      adapter = ProviderAdapter.Mock.new()
      ProviderAdapter.Mock.set_send_calls_error(adapter, :rpc_down)
      session = start_session(:open)
      p = provider(session, AcceptHandler, adapter)

      assert {:error, :rpc_down} =
               Provider.accept_request(p, %{req: 1}, AssetToken.usdc(0.25, @chain))

      assert JobSession.status(session) == :open
    end
  end

  describe "deliver/2" do
    test "deliver: writes submit on-chain and mirrors :submitted" do
      adapter = ProviderAdapter.Mock.new()
      session = start_session(:funded)
      p = provider(session, AcceptHandler, adapter)

      assert {:ok, %{status: :submitted, tx_hash: tx, deliverable: %{result: "done"}}} =
               Provider.deliver(p, %{req: 1})

      assert is_binary(tx)
      assert JobSession.status(session) == :submitted
      assert_one_call(adapter, "submit(uint256,bytes32,bytes)")
    end

    test "handler error: no write, session unchanged" do
      adapter = ProviderAdapter.Mock.new()
      session = start_session(:funded)
      p = provider(session, RejectHandler, adapter)

      assert {:error, :cannot_build} = Provider.deliver(p, %{req: 1})
      assert JobSession.status(session) == :funded
      assert ProviderAdapter.Mock.sent_calls(adapter) == []
    end

    test "does not advance the session when the chain write fails" do
      adapter = ProviderAdapter.Mock.new()
      ProviderAdapter.Mock.set_send_calls_error(adapter, :rpc_down)
      session = start_session(:funded)
      p = provider(session, AcceptHandler, adapter)

      assert {:error, :rpc_down} = Provider.deliver(p, %{req: 1})
      assert JobSession.status(session) == :funded
    end
  end

  describe "evaluate/2" do
    test "approve: writes complete on-chain, mirrors :completed, and stops the session" do
      adapter = ProviderAdapter.Mock.new()
      session = start_session(:submitted)
      ref = Process.monitor(session)
      p = provider(session, AcceptHandler, adapter)

      assert {:ok, %{status: :completed, tx_hash: tx}} = Provider.evaluate(p, %{result: "done"})
      assert is_binary(tx)
      assert_one_call(adapter, "complete(uint256,bytes32,bytes)")
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 500
    end

    test "reject: writes reject on-chain and mirrors :rejected" do
      adapter = ProviderAdapter.Mock.new()
      session = start_session(:submitted)
      p = provider(session, RejectHandler, adapter)

      assert {:ok, %{status: :rejected, info: :bad_work}} =
               Provider.evaluate(p, %{result: "bad"})

      assert_one_call(adapter, "reject(uint256,bytes32,bytes)")
    end

    test "handler without handle_evaluate/2 defers to an external evaluator" do
      adapter = ProviderAdapter.Mock.new()
      session = start_session(:submitted)
      p = provider(session, NoEvaluateHandler, adapter)

      assert {:error, :evaluate_not_supported} = Provider.evaluate(p, %{result: "done"})
      assert ProviderAdapter.Mock.sent_calls(adapter) == []
      assert JobSession.status(session) == :submitted
    end

    test "does not advance the session when the chain write fails" do
      adapter = ProviderAdapter.Mock.new()
      ProviderAdapter.Mock.set_send_calls_error(adapter, :rpc_down)
      session = start_session(:submitted)
      p = provider(session, AcceptHandler, adapter)

      assert {:error, :rpc_down} = Provider.evaluate(p, %{result: "done"})
      assert JobSession.status(session) == :submitted
    end
  end
end
