defmodule Raxol.ACP.Xochi.SolverAgentTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.{Agent, ProviderAdapter, Transport, JobApi, JobSession}
  alias Raxol.ACP.Xochi.SolverAgent

  @solver_wallet "0xfeedfacefeedfacefeedfacefeedfacefeedface"
  @evaluator "0x" <> String.duplicate("ed", 20)
  @acp_core "0x238E541BfefD82238730D00a2208E5497F1832E0"

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
          xochi_config: xochi_stub()
        ],
        opts
      )
    )
  end

  # In-process Xochi stub for accept-time intent derivation: GET /api/intent/:id
  # returns a `:quoted` intent carrying the authoritative `from_amount`. The
  # budget is sized on THIS, never the requirement's declared `amount_atomic`.
  defp xochi_stub(from_amount \\ "1000000", status \\ "quoted") do
    plug = fn conn ->
      body = %{
        "id" => "xi_1",
        "status" => status,
        "from_chain_id" => 8453,
        "to_chain_id" => 10,
        "from_token" => "0x" <> String.duplicate("11", 20),
        "to_token" => "0x" <> String.duplicate("22", 20),
        "from_amount" => from_amount,
        "to_amount" => from_amount,
        "quote_id" => "xq_1"
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    %{base_url: "https://api.xochi.fi", req_options: [plug: plug, retry: false]}
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
        "signed_intent" => %{
          "intent_id" => "xi_1",
          "quote_id" => "xq_1",
          "signature" => "0x" <> String.duplicate("11", 65),
          "nonce" => 7,
          "pull_signature" => "0x" <> String.duplicate("22", 65)
        }
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

      # Budget is the storefront fee only: 0.5% of 1_000_000 = 5_000. The
      # transfer flows via Xochi off-escrow, not through the ACP budget.
      assert budget == 5_000

      assert [{8453, [call]}] = ProviderAdapter.Mock.sent_calls(ctx.provider)
      assert call.to == @acp_core
    end

    test "the budget is the storefront fee, a fraction of the transfer, not the transfer", ctx do
      {:ok, solver} = start_solver([fee_bps: 50], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      %{{8453, "42"} => session} = SolverAgent.sessions(solver)

      # The ACP escrow holds only the storefront fee; the transfer moves through
      # Xochi. So the budget is a small fraction of the transfer, never >= it.
      assert session.budget_atomic == 5_000
      assert session.budget_atomic < session.transfer_amount_atomic
    end

    test "zero fee_bps yields a zero budget", ctx do
      {:ok, solver} = start_solver([fee_bps: 0], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{budget_atomic: 0}} = SolverAgent.sessions(solver)
    end

    test "sizes the fee on Xochi's amount, ignoring the declared amount_atomic", ctx do
      # Buyer understates amount_atomic to 1 base unit; the stub intent carries
      # the authoritative 1_000_000, so the fee is 0.5% of 1_000_000 = 5_000.
      req =
        requirement_message(
          requirement: %{
            "amount_atomic" => "1",
            "signed_intent" => %{
              "intent_id" => "xi_1",
              "quote_id" => "xq_1",
              "signature" => "0x" <> String.duplicate("11", 65),
              "nonce" => 7,
              "pull_signature" => "0x" <> String.duplicate("22", 65)
            }
          }
        )

      {:ok, solver} = start_solver([fee_bps: 50], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, req)
      Process.sleep(60)

      assert %{{8453, "42"} => session} = SolverAgent.sessions(solver)
      assert session.budget_atomic == 5_000
      assert session.transfer_amount_atomic == 1_000_000
    end

    test "fails the job closed when the intent is not in the quoted state", ctx do
      {:ok, solver} = start_solver([xochi_config: xochi_stub("1000000", "executing")], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
      # No budget was proposed on-chain: the fee was never sized on an
      # unresolved intent.
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
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
           settlement_tx_hash: "0x" <> String.duplicate("a", 64),
           receiving_tx_hash: "0x" <> String.duplicate("b", 64),
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

    test "job.funded settles only the funded job, not other pending sessions", ctx do
      settle_stub = fn _ ->
        {:ok,
         %{
           intent_id: "xochi-42",
           settlement_tx_hash: "0x" <> String.duplicate("a", 64),
           receiving_tx_hash: "0x" <> String.duplicate("b", 64),
           status: "settled"
         }}
      end

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      # Two independent jobs both reach :budget_proposed.
      Transport.Mock.deliver(ctx.transport, job_created_entry(job_id: "42"))
      Transport.Mock.deliver(ctx.transport, requirement_message(job_id: "42"))
      Transport.Mock.deliver(ctx.transport, job_created_entry(job_id: "77"))
      Transport.Mock.deliver(ctx.transport, requirement_message(job_id: "77"))
      Process.sleep(80)

      assert %{status: :budget_proposed} = SolverAgent.session(solver, {8453, "42"})
      assert %{status: :budget_proposed} = SolverAgent.session(solver, {8453, "77"})

      # Fund ONLY job 42.
      Transport.Mock.deliver(
        ctx.transport,
        %{"kind" => "system", "event" => "job.funded", "chainId" => 8453, "jobId" => "42"}
      )

      Process.sleep(80)

      # Job 42 settled; job 77 must be untouched -- a job.funded for 42 must not
      # settle (spend funds for) an unfunded job.
      assert SolverAgent.session(solver, {8453, "42"}).status == :submitted
      assert SolverAgent.session(solver, {8453, "77"}).status == :budget_proposed
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

  describe "reattach after restart (deployed funded->settle path)" do
    # Regression for #772: the deployed solver set the budget, then RESTARTED
    # (deploy/reschedule) before the buyer funded. Its in-memory session was gone
    # and the live-only SSE stream never replays the earlier entries, so the
    # funded job stayed stuck at `funded` forever -- settle was never reached.
    #
    # This exercises the SolverAgent's own `handle_job_funded/2` with NO prior
    # session, proving it rebuilds from job history and settles. (The passing
    # `--route acp` gate drives `JobSession.Provider.deliver` directly, never this
    # path -- which is why the bug shipped.)

    # Raw wire-shaped history entries: a system `job.created` (nested event map,
    # onChainJobId) and a `requirement` message. Parser.normalize/1 folds these
    # into the shape the reattach reads, same as the live stream.
    defp history_created(job_id, provider) do
      %{
        "kind" => "system",
        "event" => %{"type" => "job.created", "provider" => provider, "onChainJobId" => job_id},
        "chainId" => 8453
      }
    end

    defp history_requirement(job_id) do
      req = %{
        "src_chain_id" => 8453,
        "dst_chain_id" => 10,
        "src_token" => "0x" <> String.duplicate("11", 20),
        "dst_token" => "0x" <> String.duplicate("22", 20),
        "amount_atomic" => "1000000",
        "signed_intent" => %{
          "intent_id" => "xi_1",
          "quote_id" => "xq_1",
          "signature" => "0x" <> String.duplicate("11", 65),
          "nonce" => 7,
          "pull_signature" => "0x" <> String.duplicate("22", 65)
        }
      }

      %{
        "kind" => "message",
        "contentType" => "requirement",
        "chainId" => 8453,
        "onChainJobId" => job_id,
        "content" => Jason.encode!(req)
      }
    end

    defp funded(job_id) do
      %{"kind" => "system", "event" => "job.funded", "chainId" => 8453, "jobId" => job_id}
    end

    test "rebuilds the session from history and settles a funded job the solver never saw created",
         ctx do
      test_pid = self()

      settle_stub = fn args ->
        send(test_pid, {:settled, args})

        {:ok,
         %{
           intent_id: "xochi-reattach",
           settlement_tx_hash: "0x" <> String.duplicate("a", 64),
           receiving_tx_hash: "0x" <> String.duplicate("b", 64),
           status: "settled"
         }}
      end

      # The ACP server holds the job's history; the solver's memory does not.
      Transport.Mock.set_history(ctx.transport, {8453, 70_759}, [
        history_created(70_759, @solver_wallet),
        history_requirement(70_759)
      ])

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      # ONLY a funded event arrives (post-restart) -- no job.created, no requirement.
      Transport.Mock.deliver(ctx.transport, funded(70_759))
      Process.sleep(80)

      # The relay ran on the recovered signed intent...
      assert_received {:settled, %{signed_intent: %{"intent_id" => "xi_1"}}}

      # ...and the job advanced to submitted on-chain.
      session = SolverAgent.session(solver, {8453, 70_759})
      assert session.status == :submitted
      assert session.deliverable.intent_id == "xochi-reattach"

      # Only the submit call -- setBudget already happened before the restart, so
      # reattach does NOT re-propose the budget.
      assert [{8453, [call]}] = ProviderAdapter.Mock.sent_calls(ctx.provider)
      assert call.to == @acp_core
    end

    test "a duplicate funded event does not re-settle an already-submitted job", ctx do
      settle_count = :counters.new(1, [])

      settle_stub = fn _ ->
        :counters.add(settle_count, 1, 1)

        {:ok,
         %{
           intent_id: "xochi-dup",
           settlement_tx_hash: "0x" <> String.duplicate("a", 64),
           receiving_tx_hash: "0x" <> String.duplicate("b", 64),
           status: "settled"
         }}
      end

      Transport.Mock.set_history(ctx.transport, {8453, 70_760}, [
        history_created(70_760, @solver_wallet),
        history_requirement(70_760)
      ])

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_760))
      Process.sleep(80)
      assert SolverAgent.session(solver, {8453, 70_760}).status == :submitted

      # A replayed funded event must not spend again.
      Transport.Mock.deliver(ctx.transport, funded(70_760))
      Process.sleep(80)

      assert :counters.get(settle_count, 1) == 1
    end

    test "reattach fails closed when the funded job is not ours (no settle)", ctx do
      settle_stub = fn _ -> flunk("must not settle a job we did not provide") end

      Transport.Mock.set_history(ctx.transport, {8453, 70_761}, [
        history_created(70_761, "0xother0000000000000000000000000000000000"),
        history_requirement(70_761)
      ])

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_761))
      Process.sleep(80)

      assert SolverAgent.session(solver, {8453, 70_761}) == nil
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "reattach fails closed when history has no requirement (no settle)", ctx do
      settle_stub = fn _ -> flunk("must not settle without a recovered requirement") end

      Transport.Mock.set_history(ctx.transport, {8453, 70_762}, [
        history_created(70_762, @solver_wallet)
      ])

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_762))
      Process.sleep(80)

      assert SolverAgent.session(solver, {8453, 70_762}) == nil
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
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

  describe "plain job (hook = address(0))" do
    test "set_budget is a plain setBudget with empty hook data and a fee budget", ctx do
      {:ok, _solver} = start_solver([fee_bps: 50], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      [{8453, [call]}] = ProviderAdapter.Mock.sent_calls(ctx.provider)
      assert call.to == @acp_core

      # The calldata is exactly setBudget(jobId=42, amount=fee, data=<<>>) -- no
      # FundTransfer payload. Re-encoding with the same ABI encoder pins it
      # without hardcoding byte offsets. fee = 0.5% of 1_000_000 = 5_000.
      expected =
        Raxol.ACP.ABI.encode_call("setBudget(uint256,uint256,bytes)", [
          {"uint256", 42},
          {"uint256", 5_000},
          {"bytes", <<>>}
        ])

      assert call.data == expected
    end
  end
end
