defmodule Mix.Tasks.RaxolAcp.Order do
  @shortdoc "Place a real ACP order (buyer) against a live agent offering"

  @moduledoc """
  Live BUYER harness: creates a real on-chain ACP job for an agent's offering,
  sends the requirement, and watches the provider set the budget on-chain. This
  is the counterpart to the seller `SolverAgent` -- it produces a job the
  Virtuals UI shows and exercises the deployed solver's real on-chain `setBudget`.

  Flow (mirrors `acp-node-v2` `createJobFromOffering`):

    1. Sign a Xochi intent for the transfer (`quote_and_sign`, off-chain EIP-712).
    2. `createJob(provider, evaluator=0x0, expiredAt, description, hook=0x0)` on the
       ACP Core (a real Base tx; the buyer EOA pays gas).
    3. Resolve the assigned `jobId` from the `createJob` receipt.
    4. `send_message(jobId, requirement, "requirement")` -- retried, since the
       off-chain chat room lags the on-chain job.
    5. Poll `getJob(jobId).budget` until the provider sets it, and assert it is
       `fee_bps` of the principal.
    6. With `--fund`: `fund(jobId, budget)` so the provider is paid and settlement
       proceeds (a second Base tx).

  MOVES REAL FUNDS: `createJob`/`fund` cost gas; the Xochi settlement pull moves
  the principal (gasless via ERC-3009). `--dry-run` stops after signing (step 1),
  no on-chain writes.

  ## Env

      ORDER_KEY         buyer EOA private key (0x-hex). Signs the intent AND the
                        createJob/fund txs.
      ORDER_RPC_8453    Base JSON-RPC URL (to broadcast createJob/fund).
      ORDER_XOCHI_URL   Xochi worker (default https://api.xochi.fi).
      ORDER_XOCHI_TOKEN Xochi Member token.

  ## Flags

      --amount N        principal in USDC (default 3.00; note the solver's dynamic
                        gas floor rejects sub-~$3 today).
      --corridor F>T    origin>destination chain ids (default 8453>42161).
      --provider 0x..   the agent (seller) wallet to hire (default the raxol agent).
      --fee-bps N       expected take-rate to assert (default 8).
      --fund            after budget is observed, fund the escrow (extra Base tx).
      --dry-run         sign only, no on-chain writes.

  ## Example

      ORDER_KEY=0x... ORDER_RPC_8453=https://mainnet.base.org \\
      ORDER_XOCHI_TOKEN=<member token> \\
        mix raxol_acp.order --amount 3.00
  """

  use Mix.Task

  alias Raxol.ACP.{
    Agent,
    Auth,
    Chain,
    HookClient,
    JobApi,
    JobIdResolver,
    ProviderAdapter,
    Transport
  }

  alias Raxol.Payments.Assets
  alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol
  alias Raxol.Payments.Xochi.{PullContracts, Schemas.QuoteRequest}

  # The raxol agent (seller) wallet -- the provider a buyer hires by default.
  @default_provider "0x939ead944b5d28b86d91af1961812d3bbc46cac1"
  @offering "xochi_crosschain"
  @sla_minutes 5

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          amount: :string,
          corridor: :string,
          provider: :string,
          fee_bps: :integer,
          fund: :boolean,
          dry_run: :boolean
        ]
      )

    Application.ensure_all_started(:raxol_acp)

    cfg = build_config(opts)
    trust_pull_contracts()

    log(
      "buyer=#{cfg.buyer}  provider=#{cfg.provider}  corridor=#{cfg.from}->#{cfg.to}  amount=#{cfg.amount} USDC"
    )

    # 1. Sign the Xochi intent (off-chain).
    {:ok, bundle} = sign_intent(cfg)
    requirement = requirement(cfg, bundle)
    log("signed Xochi intent: #{bundle[:intent_id] || bundle["intent_id"]}")

    if opts[:dry_run] do
      log("--dry-run: signed only, no on-chain writes. requirement=#{inspect(requirement)}")
    else
      place(cfg, requirement, Keyword.get(opts, :fund, false))
    end
  end

  # -- Orchestration --

  defp place(cfg, requirement, fund?) do
    {agent, resolver} = start_buyer(cfg)

    # 2. createJob on-chain.
    expired_at = System.system_time(:second) + @sla_minutes * 60 + 60

    {:ok, tx} =
      HookClient.create_job(cfg.provider_adapter, cfg.from, cfg.core, %{
        provider: cfg.provider,
        evaluator: zero_address(),
        expired_at: expired_at,
        hook_address: zero_address(),
        description: @offering
      })

    log("createJob tx: #{explorer(cfg.from)}#{tx}")

    # 3. Resolve the on-chain jobId from the receipt (retries until mined).
    job_id = await_job_id(resolver, cfg, tx)
    log("jobId: #{job_id}")

    # 4. Send the requirement (retry: the chat room lags the on-chain job).
    :ok = send_requirement(agent, cfg.from, job_id, requirement)
    log("requirement sent for job #{job_id}")

    # 5. Watch the provider set the budget on-chain and assert the take-rate.
    budget = await_budget(cfg, job_id)
    expected = div(cfg.principal_atomic * cfg.fee_bps, 10_000)
    realized_bps = Float.round(budget / cfg.principal_atomic * 10_000, 3)

    log("provider setBudget = #{budget} base units (#{realized_bps} bps)")

    if budget == expected do
      log("OK: budget == #{cfg.fee_bps} bps of the principal")
    else
      log("WARN: budget #{budget} != expected #{expected} (#{cfg.fee_bps} bps)")
    end

    log("job #{job_id} is live -- view it at https://app.virtuals.io/acp")

    if fund?, do: fund_job(cfg, job_id, budget)
  end

  defp fund_job(cfg, job_id, budget) do
    log("funding escrow: approving #{budget} USDC to the ACP Core, then fund(#{job_id})...")
    :ok = approve_usdc(cfg, budget)
    {:ok, tx} = HookClient.fund(cfg.provider_adapter, cfg.from, cfg.core, job_id, budget)
    log("fund tx: #{explorer(cfg.from)}#{tx} -- provider will now settle + deliver")
  end

  # -- Steps --

  defp sign_intent(cfg) do
    request = %QuoteRequest{
      wallet: cfg.buyer,
      from_chain_id: cfg.from,
      to_chain_id: cfg.to,
      from_token: cfg.src_token,
      to_token: cfg.dst_token,
      from_amount: Integer.to_string(cfg.principal_atomic),
      settlement_preference: "public",
      slippage_bps: 50
    }

    XochiProtocol.quote_and_sign(cfg.xochi_config, request, cfg.wallet_mod)
  end

  defp requirement(cfg, bundle) do
    %{
      "src_chain_id" => cfg.from,
      "dst_chain_id" => cfg.to,
      "src_token" => cfg.src_token,
      "dst_token" => cfg.dst_token,
      "amount_atomic" => Integer.to_string(cfg.principal_atomic),
      "settlement_preference" => "public",
      "signed_intent" => Map.new(bundle, fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp start_buyer(cfg) do
    {:ok, auth} =
      Auth.start_link(
        provider: cfg.provider_adapter,
        server_url: cfg.server_url,
        chain_id: cfg.from
      )

    transport =
      Transport.SSE.new(auth: auth, server_url: cfg.server_url, supported_chain_ids: [cfg.from])

    api = JobApi.HTTP.new(auth: auth, server_url: cfg.server_url, chain_ids: [cfg.from])

    {:ok, agent} =
      Agent.start_link(
        provider: cfg.provider_adapter,
        transport: transport,
        api: api,
        wallet_address: cfg.buyer,
        supported_chain_ids: [cfg.from],
        default_role: :client
      )

    Agent.subscribe(agent)
    Agent.start_stream(agent)

    resolver = %{
      adapter: JobIdResolver.Receipt,
      config: %{
        event_signature: "JobCreated(uint256,address,address,address,uint256,address)",
        topic_index: 1
      }
    }

    {agent, resolver}
  end

  defp await_job_id(resolver, cfg, tx, tries \\ 30)

  defp await_job_id(_resolver, _cfg, tx, 0),
    do: Mix.raise("createJob #{tx} not mined / jobId not decodable in time")

  defp await_job_id(resolver, cfg, tx, tries) do
    case JobIdResolver.resolve(resolver, cfg.provider_adapter, cfg.from, tx) do
      {:ok, job_id} -> job_id
      :pending -> Process.sleep(2_000) && await_job_id(resolver, cfg, tx, tries - 1)
      {:error, reason} -> Mix.raise("jobId resolve failed: #{inspect(reason)}")
    end
  end

  # Retry, per acp-node-v2: the off-chain chat room may not exist immediately
  # after the on-chain createJob.
  defp send_requirement(agent, chain_id, job_id, requirement, tries \\ 6)

  defp send_requirement(_agent, _chain_id, job_id, _requirement, 0),
    do: Mix.raise("could not deliver requirement for job #{job_id} (chat room never ready)")

  defp send_requirement(agent, chain_id, job_id, requirement, tries) do
    case Agent.send_message(
           agent,
           {chain_id, to_string(job_id)},
           Jason.encode!(requirement),
           "requirement"
         ) do
      :ok ->
        :ok

      _err ->
        Process.sleep(2_000)
        send_requirement(agent, chain_id, job_id, requirement, tries - 1)
    end
  end

  defp await_budget(cfg, job_id, tries \\ 60)

  defp await_budget(_cfg, job_id, 0),
    do: Mix.raise("provider never set a budget for job #{job_id}")

  defp await_budget(cfg, job_id, tries) do
    case read_budget(cfg, job_id) do
      {:ok, budget} when budget > 0 -> budget
      _ -> Process.sleep(3_000) && await_budget(cfg, job_id, tries - 1)
    end
  end

  # -- On-chain reads/writes not covered by HookClient --

  # getJob(jobId) -> (client, status, provider, expiredAt, evaluator, hook, budget, description).
  # budget is the 7th static word (index 6). The trailing string is offset-encoded
  # after the static head, so word 6 is the budget inline.
  defp read_budget(cfg, job_id) do
    selector = binary_part(ExKeccak.hash_256("getJob(uint256)"), 0, 4)

    data =
      "0x" <> Base.encode16(selector <> <<job_id::unsigned-big-integer-size(256)>>, case: :lower)

    body = %{
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [%{to: cfg.core, data: data}, "latest"]
    }

    case Req.post(cfg.rpc, json: body) do
      {:ok, %{status: 200, body: %{"result" => "0x" <> hex}}} when byte_size(hex) >= 14 * 64 ->
        raw = Base.decode16!(hex, case: :mixed)

        <<_head::binary-size(6 * 32), budget::unsigned-big-integer-size(256), _rest::binary>> =
          raw

        {:ok, budget}

      _ ->
        :not_ready
    end
  end

  defp approve_usdc(cfg, amount) do
    call = %{
      to: cfg.src_token,
      data:
        Raxol.ACP.ABI.encode_call("approve(address,uint256)", [
          {"address", cfg.core},
          {"uint256", amount}
        ]),
      value: 0
    }

    case ProviderAdapter.send_calls(cfg.provider_adapter, cfg.from, [call]) do
      {:ok, _} -> :ok
      err -> Mix.raise("USDC approve failed: #{inspect(err)}")
    end
  end

  # -- Config / helpers --

  defp build_config(opts) do
    key_hex = fetch_env!("ORDER_KEY")
    rpc = fetch_env!("ORDER_RPC_8453")
    {from, to} = parse_corridor(Keyword.get(opts, :corridor, "8453>42161"))
    amount = Keyword.get(opts, :amount, "3.00")

    {:ok, src_token} = Assets.address(from, "USDC")
    {:ok, dst_token} = Assets.address(to, "USDC")
    principal_atomic = Assets.to_atomic(Decimal.new(amount), Assets.decimals(from, src_token))

    provider_adapter =
      ProviderAdapter.JSONRPC.new(chains: %{from => rpc}, private_key: decode_key(key_hex))

    %{
      buyer: wallet_mod().address(),
      wallet_mod: wallet_mod(),
      provider_adapter: provider_adapter,
      provider: Keyword.get(opts, :provider, @default_provider),
      from: from,
      to: to,
      amount: amount,
      principal_atomic: principal_atomic,
      src_token: src_token,
      dst_token: dst_token,
      fee_bps: Keyword.get(opts, :fee_bps, 8),
      rpc: rpc,
      core: Chain.mainnet().acp_core_address,
      server_url: Chain.mainnet().acp_server_url,
      xochi_config: %{
        base_url: System.get_env("ORDER_XOCHI_URL", "https://api.xochi.fi"),
        auth_token: System.get_env("ORDER_XOCHI_TOKEN", "")
      }
    }
  end

  # The buyer signs the Xochi intent with the same ORDER_KEY the provider adapter uses.
  defmodule Wallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "ORDER_KEY"
  end

  defp wallet_mod, do: Wallet

  # Trust the verified XochiPull contracts so the intent's origin-pull authorization
  # passes the anti-drain pin (Riddler #591; same set config/runtime.exs uses).
  defp trust_pull_contracts do
    Application.put_env(:raxol_payments, :pull_solver_allowlist, PullContracts.pull_recipients())
    Application.put_env(:raxol_payments, :pull_require_solver_pin, true)
  end

  defp parse_corridor(spec) do
    [from, to] = String.split(spec, ">", parts: 2)
    {String.to_integer(String.trim(from)), String.to_integer(String.trim(to))}
  end

  defp decode_key("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_key(hex), do: Base.decode16!(hex, case: :mixed)

  defp zero_address, do: "0x0000000000000000000000000000000000000000"

  defp fetch_env!(name) do
    case System.get_env(name) do
      nil -> Mix.raise("set #{name}")
      "" -> Mix.raise("set #{name}")
      v -> v
    end
  end

  @explorers %{
    1 => "https://etherscan.io/tx/",
    10 => "https://optimistic.etherscan.io/tx/",
    137 => "https://polygonscan.com/tx/",
    8453 => "https://basescan.org/tx/",
    42_161 => "https://arbiscan.io/tx/"
  }

  defp explorer(chain_id), do: Map.get(@explorers, chain_id, "")

  defp log(msg), do: Mix.shell().info("[order] " <> msg)
end
