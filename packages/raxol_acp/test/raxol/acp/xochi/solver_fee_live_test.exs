defmodule Raxol.ACP.Xochi.SolverFeeLiveTest do
  @moduledoc """
  Live gate: proves the deployed solver sizes the on-chain ACP budget at exactly
  `XOCHI_FEE_BPS` basis points of the AUTHORITATIVE principal -- the number the
  buyer signed against Xochi, read back off the live worker, not the relayed
  `amount_atomic`. This is the take-rate validation: with `XOCHI_FEE_BPS=8` it
  asserts the budget the solver would write on-chain is 8 bps of the principal.

  What is real here:

    * the buyer quotes + signs a real Xochi intent for a known principal
      (`Raxol.Payments.Protocols.Xochi.quote_and_sign/3`, an off-chain EIP-712
      signature -- NO funds move, NO settlement, NO on-chain tx);
    * the real `Raxol.ACP.Xochi.SolverAgent` runs its production path
      (`IntentDeriver.resolve/2` against the live Xochi worker -> `budget_for/2`
      -> `HookClient.set_budget/6`), with `fee_bps` read from the same
      `XOCHI_FEE_BPS` env the deployed solver reads.

  What is faked, and why: the on-chain WRITE is captured via
  `ProviderAdapter.Mock` rather than sent, because a real `setBudget` needs a real
  on-chain job to exist (the full marketplace lifecycle). The budget VALUE is not
  faked -- it is decoded straight out of the `setBudget(uint256,uint256,bytes)`
  calldata the solver produced, so this asserts the exact on-chain wire amount.

  Tagged `:live_solver_fee`; excluded by default, compiled only when the env is
  present. Reuses the ACP order gate's env so it slots into the same run:

      XOCHI_ORDER_LIVE_URL=https://api.xochi.fi \\
      XOCHI_ORDER_LIVE_TOKEN=<Xochi Member token> XOCHI_ORDER_LIVE_KEY=0x<key> \\
      XOCHI_FEE_BPS=8 \\
        mix test --only live_solver_fee test/raxol/acp/xochi/solver_fee_live_test.exs

  Optional overrides: `XOCHI_ORDER_AMOUNT` (human USDC principal, default "5.00"),
  `XOCHI_ORDER_CORRIDORS` ("from>to", default "8453>42161").
  """

  use ExUnit.Case, async: false

  @moduletag :live_solver_fee
  @moduletag timeout: 120_000

  if System.get_env("XOCHI_ORDER_LIVE_URL") && System.get_env("XOCHI_ORDER_LIVE_KEY") do
    alias Raxol.ACP.{Agent, Chain, JobApi, ProviderAdapter, Transport}
    alias Raxol.ACP.Xochi.SolverAgent
    alias Raxol.Payments.Assets
    alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol
    alias Raxol.Payments.Xochi.Schemas.QuoteRequest

    defmodule LiveWallet do
      @moduledoc false
      use Raxol.Payments.Wallets.Env, env_var: "XOCHI_ORDER_LIVE_KEY"
    end

    setup do
      pin_pull_recipients()

      xochi_config = %{
        base_url: System.fetch_env!("XOCHI_ORDER_LIVE_URL"),
        auth_token: System.get_env("XOCHI_ORDER_LIVE_TOKEN", "")
      }

      {from, to} = corridor()

      {:ok,
       xochi_config: xochi_config,
       fee_bps: String.to_integer(System.get_env("XOCHI_FEE_BPS", "8")),
       from: from,
       to: to,
       amount: System.get_env("XOCHI_ORDER_AMOUNT", "5.00")}
    end

    test "the solver sizes the on-chain ACP budget at fee_bps of the live-signed principal",
         ctx do
      wallet = LiveWallet.address()

      {:ok, src_token} = Assets.address(ctx.from, "USDC")
      {:ok, dst_token} = Assets.address(ctx.to, "USDC")

      principal_atomic =
        Assets.to_atomic(Decimal.new(ctx.amount), Assets.decimals(ctx.from, src_token))

      # 1. Buyer signs a real Xochi intent for `principal_atomic`. Off-chain only.
      request = %QuoteRequest{
        wallet: wallet,
        from_chain_id: ctx.from,
        to_chain_id: ctx.to,
        from_token: src_token,
        to_token: dst_token,
        from_amount: Integer.to_string(principal_atomic),
        settlement_preference: "public",
        slippage_bps: 50
      }

      {:ok, bundle} = XochiProtocol.quote_and_sign(ctx.xochi_config, request, LiveWallet)

      requirement = %{
        "src_chain_id" => ctx.from,
        "dst_chain_id" => ctx.to,
        "src_token" => src_token,
        "dst_token" => dst_token,
        "amount_atomic" => Integer.to_string(principal_atomic),
        "settlement_preference" => "public",
        "signed_intent" => Map.new(bundle, fn {k, v} -> {to_string(k), v} end)
      }

      # 2. Real SolverAgent, production path. The on-chain write is captured (Mock)
      #    but the budget VALUE it produces is real and asserted below.
      {solver, provider} = start_solver(wallet, ctx)
      job_id = Integer.to_string(System.unique_integer([:positive]))

      Agent.start_stream(solver.agent)
      Transport.Mock.deliver(solver.transport, job_created(ctx.from, job_id, wallet))
      Transport.Mock.deliver(solver.transport, requirement_msg(ctx.from, job_id, requirement))

      # 3. Solver resolves the intent off LIVE Xochi and proposes the budget.
      session = await_budget(solver.pid, {ctx.from, job_id})

      expected = div(principal_atomic * ctx.fee_bps, 10_000)

      assert session.status == :budget_proposed,
             "solver did not propose a budget (status #{inspect(session.status)})"

      assert session.transfer_amount_atomic == principal_atomic,
             "solver read a different authoritative principal from Xochi: " <>
               "#{session.transfer_amount_atomic} != #{principal_atomic}"

      assert session.budget_atomic == expected,
             "computed budget #{session.budget_atomic} is not #{ctx.fee_bps} bps of #{principal_atomic}"

      # 4. The ON-CHAIN calldata carries exactly that budget.
      assert [{_chain, [call]}] = ProviderAdapter.Mock.sent_calls(provider)
      assert call.to == Chain.mainnet().acp_core_address

      assert onchain_amount(call.data) == expected,
             "on-chain setBudget amount != #{ctx.fee_bps} bps of the principal"

      realized_bps = Float.round(session.budget_atomic / principal_atomic * 10_000, 3)

      IO.puts(
        "[live_solver_fee] principal=#{principal_atomic} budget=#{session.budget_atomic} " <>
          "=> #{realized_bps} bps (fee_bps=#{ctx.fee_bps}, corridor #{ctx.from}->#{ctx.to})"
      )
    end

    # -- Harness --

    defp start_solver(wallet, ctx) do
      transport = Transport.Mock.new()
      job_api = JobApi.Mock.new(me: %{wallet_address: wallet, name: "raxol"})
      provider = ProviderAdapter.Mock.new(address: wallet, supported_chain_ids: [ctx.from])

      {:ok, agent} =
        Agent.start_link(
          transport: transport,
          api: job_api,
          wallet_address: wallet,
          supported_chain_ids: [ctx.from],
          default_role: :provider
        )

      {:ok, pid} =
        SolverAgent.start_link(
          agent: agent,
          provider: provider,
          wallet_address: wallet,
          evaluator_address: wallet,
          chain_id: ctx.from,
          acp_core_address: Chain.mainnet().acp_core_address,
          fee_bps: ctx.fee_bps,
          xochi_config: ctx.xochi_config
        )

      {%{pid: pid, agent: agent, transport: transport}, provider}
    end

    defp job_created(chain_id, job_id, provider) do
      %{
        "kind" => "system",
        "event" => "job.created",
        "chainId" => chain_id,
        "jobId" => job_id,
        "provider" => provider
      }
    end

    defp requirement_msg(chain_id, job_id, requirement) do
      %{
        "kind" => "message",
        "contentType" => "requirement",
        "chainId" => chain_id,
        "jobId" => job_id,
        "content" => Jason.encode!(requirement)
      }
    end

    # Poll until the solver proposes (or fails) the budget for this job. The only
    # blocking step is the live IntentDeriver GET; 20s is generous.
    defp await_budget(solver, key, remaining_ms \\ 20_000)

    defp await_budget(_solver, key, remaining_ms) when remaining_ms <= 0 do
      flunk("solver never proposed a budget for #{inspect(key)} within the deadline")
    end

    defp await_budget(solver, key, remaining_ms) do
      case SolverAgent.session(solver, key) do
        %{status: :budget_proposed} = session ->
          session

        %{status: :failed} = session ->
          flunk("solver failed the job: #{inspect(session)}")

        _ ->
          Process.sleep(200)
          await_budget(solver, key, remaining_ms - 200)
      end
    end

    # setBudget(uint256 jobId, uint256 amount, bytes data): the amount is the
    # second 32-byte word after the 4-byte selector.
    defp onchain_amount(
           <<_selector::binary-size(4), _job_id::binary-size(32),
             amount::unsigned-big-integer-size(256), _rest::binary>>
         ),
         do: amount

    defp corridor do
      case System.get_env("XOCHI_ORDER_CORRIDORS") do
        nil ->
          {8453, 42_161}

        spec ->
          [from, to] = spec |> String.split(">", parts: 2)
          {String.to_integer(String.trim(from)), String.to_integer(String.trim(to))}
      end
    end

    # Pin the origin-pull recipient to the verified XochiPull contracts (Riddler
    # #591; Raxol.Payments.Xochi.PullContracts) with the pin REQUIRED. Origin pull
    # + ERC-3009 now route through those per-chain contracts, not the bare solver
    # EOA the legacy pin matched, so this keeps the anti-drain guard ON (a quote
    # whose pull `to` is not a verified contract still aborts before signing) and
    # doubles as a fund-free check that live routing pulls to a known contract.
    # Restored on exit.
    defp pin_pull_recipients do
      prior_allowlist = Application.get_env(:raxol_payments, :pull_solver_allowlist)
      prior_require = Application.get_env(:raxol_payments, :pull_require_solver_pin)

      Application.put_env(
        :raxol_payments,
        :pull_solver_allowlist,
        Raxol.Payments.Xochi.PullContracts.pull_recipients()
      )

      Application.put_env(:raxol_payments, :pull_require_solver_pin, true)

      on_exit(fn ->
        restore(:pull_solver_allowlist, prior_allowlist)
        restore(:pull_require_solver_pin, prior_require)
      end)
    end

    defp restore(key, nil), do: Application.delete_env(:raxol_payments, key)
    defp restore(key, value), do: Application.put_env(:raxol_payments, key, value)
  end
end
