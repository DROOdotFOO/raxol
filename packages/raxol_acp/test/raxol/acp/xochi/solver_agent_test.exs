defmodule Raxol.ACP.Xochi.SolverAgentTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.{Agent, ProviderAdapter, Transport, JobApi, JobSession}
  alias Raxol.ACP.Xochi.SolverAgent
  alias Raxol.ACP.Hooks.FundTransfer

  @solver_wallet "0xfeedfacefeedfacefeedfacefeedfacefeedface"
  @evaluator "0x" <> String.duplicate("ed", 20)
  @acp_core "0x238E541BfefD82238730D00a2208E5497F1832E0"
  @fund_transfer_hook "0x0EaD25150985Bce0B4925c54E4ee1D856381A86B"

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    transport = Transport.Mock.new()
    job_api = JobApi.Mock.new(me: %{wallet_address: @solver_wallet, name: "Xochi"})

    provider =
      ProviderAdapter.Mock.new(address: @solver_wallet, supported_chain_ids: [8453])

    {:ok, agent} =
      Agent.start_link(
        transport: transport,
        api: job_api,
        wallet_address: @solver_wallet,
        supported_chain_ids: [8453],
        default_role: :provider
      )

    {:ok, transport: transport, api: job_api, provider: provider, agent: agent}
  end

  defp start_solver(opts, ctx) do
    SolverAgent.start_link(
      Keyword.merge(
        [
          agent: ctx.agent,
          provider: ctx.provider,
          wallet_address: @solver_wallet,
          evaluator_address: @evaluator,
          chain_id: 8453,
          acp_core_address: @acp_core,
          fund_transfer_hook_address: @fund_transfer_hook
        ],
        opts
      )
    )
  end

  defp job_created_entry(opts \\ []) do
    %{
      "kind" => "system",
      "event" => "job.created",
      "chainId" => 8453,
      "jobId" => Keyword.get(opts, :job_id, "42"),
      "provider" => Keyword.get(opts, :provider, @solver_wallet)
    }
  end

  defp requirement_message(opts \\ []) do
    req =
      Keyword.get(opts, :requirement, %{
        "src_chain_id" => 8453,
        "dst_chain_id" => 10,
        "src_token" => "0x" <> String.duplicate("11", 20),
        "dst_token" => "0x" <> String.duplicate("22", 20),
        "amount_atomic" => "1000000",
        "destination" => "0x" <> String.duplicate("ab", 20),
        "slippage_bps" => 50
      })

    %{
      "kind" => "message",
      "contentType" => "requirement",
      "chainId" => 8453,
      "jobId" => Keyword.get(opts, :job_id, "42"),
      "content" => Jason.encode!(req)
    }
  end

  describe "job acceptance filtering" do
    test "ignores jobs whose provider is someone else", ctx do
      {:ok, solver} = start_solver([], ctx)

      Agent.start_stream(ctx.agent)
      Transport.Mock.deliver(ctx.transport, job_created_entry(provider: "0xother"))
      Process.sleep(40)

      assert SolverAgent.sessions(solver) == %{}
    end

    test "accepts jobs targeting our wallet address", ctx do
      {:ok, solver} = start_solver([], ctx)

      Agent.start_stream(ctx.agent)
      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Process.sleep(40)

      assert %{{8453, "42"} => %{status: :awaiting_requirement}} = SolverAgent.sessions(solver)
    end

    test "case-insensitive on the provider address", ctx do
      {:ok, solver} = start_solver([], ctx)
      Agent.start_stream(ctx.agent)

      upper = String.upcase(@solver_wallet)
      Transport.Mock.deliver(ctx.transport, job_created_entry(provider: upper))
      Process.sleep(40)

      assert SolverAgent.sessions(solver) |> map_size() == 1
    end
  end

  describe "budget proposal" do
    test "after job_created + requirement, submits set_budget on-chain", ctx do
      {:ok, solver} = start_solver([fee_bps: 50], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :budget_proposed, budget_atomic: budget}} =
               SolverAgent.sessions(solver)

      # 0.5% of 1_000_000 = 5_000.
      assert budget == 5_000

      assert [{8453, [call]}] = ProviderAdapter.Mock.sent_calls(ctx.provider)
      assert call.to == @acp_core
    end

    test "fee_bps clamps to a minimum of 1", ctx do
      {:ok, solver} = start_solver([fee_bps: 0], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{budget_atomic: 1}} = SolverAgent.sessions(solver)
    end

    test "malformed requirement marks the session :failed", ctx do
      {:ok, solver} = start_solver([], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())

      bad =
        %{
          "kind" => "message",
          "contentType" => "requirement",
          "chainId" => 8453,
          "jobId" => "42",
          "content" => "not-json"
        }

      Transport.Mock.deliver(ctx.transport, bad)
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
      # No on-chain calls were made.
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end
  end

  describe "settle flow" do
    test "on job.funded, runs settle_fn and submits on-chain", ctx do
      settle_stub = fn _ ->
        {:ok,
         %{
           intent_id: "xochi-1",
           quote_id: "q-1",
           src_tx_hash: "0x" <> String.duplicate("a", 64),
           dst_tx_hash: "0x" <> String.duplicate("b", 64),
           status: "settled"
         }}
      end

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())

      Transport.Mock.deliver(
        ctx.transport,
        %{
          "kind" => "system",
          "event" => "job.funded",
          "chainId" => 8453,
          "jobId" => "42"
        }
      )

      Process.sleep(80)

      assert %{{8453, "42"} => session} = SolverAgent.sessions(solver)
      assert session.status == :submitted
      assert session.deliverable.intent_id == "xochi-1"

      # Two ProviderAdapter calls: set_budget then submit.
      assert length(ProviderAdapter.Mock.sent_calls(ctx.provider)) == 2
    end

    test "settle_fn failure marks the session :failed; no submit call", ctx do
      settle_stub = fn _ -> {:error, :solver_offline} end

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())

      Transport.Mock.deliver(
        ctx.transport,
        %{
          "kind" => "system",
          "event" => "job.funded",
          "chainId" => 8453,
          "jobId" => "42"
        }
      )

      Process.sleep(80)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
      # Just set_budget; no submit.
      assert length(ProviderAdapter.Mock.sent_calls(ctx.provider)) == 1
    end
  end

  describe "completion" do
    test "job.completed event updates session status", ctx do
      {:ok, solver} = start_solver([], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Process.sleep(40)

      Transport.Mock.deliver(
        ctx.transport,
        %{
          "kind" => "system",
          "event" => "job.completed",
          "chainId" => 8453,
          "jobId" => "42"
        }
      )

      Process.sleep(40)

      session = SolverAgent.session(solver, {8453, "42"})
      assert session.status == :completed
    end
  end

  describe "encode/decode consistency with FundTransfer" do
    test "the on-chain set_budget call carries the right FundTransfer data", ctx do
      {:ok, _solver} = start_solver([], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      [{8453, [call]}] = ProviderAdapter.Mock.sent_calls(ctx.provider)
      # Extract the dynamic bytes payload from the calldata. setBudget has
      # selector(4) + 3 head words(96) = 100 bytes; the bytes length lives at
      # offset 96 (third head slot pointer was at offset 100 from start of
      # encoded args, so 64 from start of all head + 4 selector).
      # Easier: re-encode the expected hook data and find it in the calldata.
      expected_data =
        FundTransfer.encode_set_budget_data(1_000_000, "0x" <> String.duplicate("ab", 20))

      assert String.contains?(call.data, expected_data)
    end
  end
end
