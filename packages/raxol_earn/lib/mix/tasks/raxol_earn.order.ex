defmodule Mix.Tasks.RaxolEarn.Order do
  @shortdoc "Place a real ACP order (buyer) against a live agent offering"

  @moduledoc """
  Live BUYER harness: creates a real on-chain ACP job for an agent's offering,
  sends the requirement, and watches the provider set the budget on-chain. This
  is the counterpart to the seller `SolverAgent` -- it produces a job the
  Virtuals UI shows and exercises the deployed solver's real on-chain `setBudget`.

  Flow (mirrors `acp-node-v2` `createJobFromOffering`):

    1. Sign a Xochi intent for the transfer AS the buyer agent (off-chain EIP-712;
       an SCA signs ERC-1271).
    2. `createJob(provider, evaluator=0x0, expiredAt, description, hook=0x0)` on the
       ACP Core.
    3. Resolve the assigned `jobId` from the `createJob` receipt.
    4. `send_message(jobId, requirement, "requirement")` to the chat room (retried,
       since it lags the on-chain job).
    5. Poll `getJob(jobId).budget` until the provider sets it, and assert it is
       `fee_bps` of the principal.
    6. With `--fund`: approve + `fund(jobId, budget)` so the provider is paid and
       settlement proceeds.

  ## Signer backends (`--signer`)

  The buyer must be a REGISTERED Virtuals agent to post messages, so the default
  drives a managed SCA agent:

    * `privy` (default) -- Virtuals-delegated signing via the Node signer sidecar
      (`priv/signer_sidecar`); gas is Alchemy-sponsored (no ETH needed). The buyer
      is the managed SCA at `RAXOL_ACP_WALLET_ADDRESS`; the intent is signed locally
      as that SCA (`ORDER_KEY` session key -> ERC-1271).
    * `sca` -- direct ERC-4337: the `ORDER_KEY` session key signs UserOps submitted
      to your own bundler + paymaster (`ORDER_BUNDLER_URL`, `ORDER_PAYMASTER_POLICY`).
    * `eoa` -- raw EOA from `ORDER_KEY`. NOT a registered agent (messaging 404s);
      on-chain-only testing.

  MOVES REAL FUNDS on `--fund` (the fee escrow + the Xochi settlement pull). Gas is
  sponsored under `privy`. `--dry-run` stops after signing (step 1).

  ## Env

      ORDER_KEY          session-key EOA (0x-hex): signs the intent, and -- under
                         sca/eoa -- the on-chain txs.
      ORDER_RPC_8453     Base JSON-RPC (reads; eoa/sca broadcast). Default: mainnet.
      ORDER_XOCHI_TOKEN  Xochi Member token.  ORDER_XOCHI_URL default api.xochi.fi.

      # `privy` backend (delegated sidecar) -- from the agent's op item:
      RAXOL_ACP_WALLET_ADDRESS      the managed SCA agent (the buyer).
      RAXOL_ACP_WALLET_ID           Privy wallet id.
      RAXOL_ACP_SIGNER_PRIVATE_KEY  P-256 authorization key (base64 PKCS#8).
      PRIVY_APP_ID                  Virtuals Privy app id.

  ## Flags

      --signer B         privy (default) | sca | eoa
      --amount N         principal in USDC (default 3.00; the solver's dynamic gas
                         floor rejects sub-~$3 today).
      --corridor F>T     origin>destination chain ids (default 8453>42161).
      --provider 0x..    the agent (seller) wallet to hire (default the raxol agent).
      --fee-bps N        expected take-rate to assert (default 8).
      --job-id N         resume an existing job (skip createJob).
      --fund             after budget is observed, fund the escrow + settle.
      --dry-run          sign only, no on-chain writes.

  ## Example (delegated Privy, the default)

      ORDER_KEY=0x<session key> ORDER_XOCHI_TOKEN=<member token> \\
      RAXOL_ACP_WALLET_ADDRESS=0x<agent> RAXOL_ACP_WALLET_ID=<id> \\
      RAXOL_ACP_SIGNER_PRIVATE_KEY=<p256> PRIVY_APP_ID=<app id> \\
        mix raxol_earn.order --amount 3.00
  """

  use Mix.Task

  alias Raxol.Earn.{
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

  # Nested wallet modules (defined below) -- alias so they resolve everywhere.
  alias __MODULE__.{ScaWallet, Signer, Sma7702Wallet}

  # The raxol agent (seller) wallet -- the provider a buyer hires by default.
  @default_provider "0x939ead944b5d28b86d91af1961812d3bbc46cac1"
  @sca_account "0x468aeae798b3a6548ac2401d276f83afdc172283"
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
          dry_run: :boolean,
          job_id: :integer,
          signer: :string
        ]
      )

    Application.ensure_all_started(:raxol_earn)

    cfg = build_config(opts)
    trust_pull_contracts()

    log(
      "buyer=#{cfg.buyer}  provider=#{cfg.provider}  corridor=#{cfg.from}->#{cfg.to}  amount=#{cfg.amount} USDC"
    )

    # 1. Sign the Xochi intent (off-chain).
    bundle =
      case sign_intent(cfg) do
        {:ok, bundle} -> bundle
        {:error, reason} -> Mix.raise(sign_intent_error(reason))
      end

    requirement = requirement(cfg, bundle)
    log("signed Xochi intent: #{bundle[:intent_id] || bundle["intent_id"]}")

    if opts[:dry_run] do
      log("--dry-run: signed only, no on-chain writes. requirement=#{inspect(requirement)}")
    else
      place(cfg, requirement, opts)
    end
  end

  # -- Orchestration --

  defp place(cfg, requirement, opts) do
    {agent, resolver} = start_buyer(cfg)

    # 2. createJob on-chain (or resume an existing job with --job-id).
    job_id =
      case Keyword.get(opts, :job_id) do
        nil -> create_and_resolve(cfg, resolver)
        existing -> tap(existing, fn id -> log("resuming job #{id} (skip createJob)") end)
      end

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

    if Keyword.get(opts, :fund, false), do: fund_job(cfg, job_id, budget)
  end

  defp create_and_resolve(cfg, resolver) do
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

    job_id = await_job_id(resolver, cfg, tx)
    log("jobId: #{job_id}")
    job_id
  end

  # approve (USDC) + fund (ACP Core) batched into ONE UserOp, per acp-node-v2. A
  # standalone approve to a token contract is not sponsored by the Virtuals
  # paymaster; batched with the ACP-core fund call, the whole UserOp is.
  defp fund_job(cfg, job_id, budget) do
    log("funding escrow: batched approve + fund(#{job_id}) in one sponsored UserOp...")

    calls = [
      %{
        to: cfg.src_token,
        data:
          Raxol.Earn.ABI.encode_call("approve(address,uint256)", [
            {"address", cfg.core},
            {"uint256", budget}
          ]),
        value: 0
      },
      %{
        to: cfg.core,
        data:
          Raxol.Earn.ABI.encode_call("fund(uint256,uint256,bytes)", [
            {"uint256", job_id},
            {"uint256", budget},
            {"bytes", <<>>}
          ]),
        value: 0
      }
    ]

    case ProviderAdapter.send_calls(cfg.provider_adapter, cfg.from, calls) do
      {:ok, txs} ->
        log("funded (approve+fund batched): #{inspect(txs)} -- provider will settle + deliver")

      err ->
        Mix.raise("fund failed: #{inspect(err)}")
    end
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

    XochiProtocol.quote_and_sign(cfg.xochi_config, request, cfg.intent_wallet)
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
  defp send_requirement(agent, chain_id, job_id, requirement, tries \\ 12)

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

      err ->
        log("send_message attempt #{13 - tries} failed: #{inspect(err)}")
        Process.sleep(3_000)
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
      {:ok, %{status: 200, body: %{"result" => "0x" <> hex}}} when byte_size(hex) >= 8 * 64 ->
        raw = Base.decode16!(hex, case: :mixed)

        # Dynamic-struct return: a leading offset word, then the head (client,
        # status, provider, expiredAt, evaluator, hook, budget). budget is word 7
        # -- skip the offset word + the six preceding fields.
        <<_lead::binary-size(7 * 32), budget::unsigned-big-integer-size(256), _rest::binary>> =
          raw

        {:ok, budget}

      _ ->
        :not_ready
    end
  end

  # -- Config / helpers --

  defp build_config(opts) do
    rpc = System.get_env("ORDER_RPC_8453", Chain.mainnet().rpc_url)
    {from, to} = parse_corridor(Keyword.get(opts, :corridor, "8453>42161"))
    amount = Keyword.get(opts, :amount, "3.00")

    src_token = usdc_address!(from, "origin")
    dst_token = usdc_address!(to, "destination")
    principal_atomic = Assets.to_atomic(Decimal.new(amount), Assets.decimals(from, src_token))

    signer = Keyword.get(opts, :signer, "privy")
    {provider_adapter, buyer, intent_wallet} = build_signer(signer, from, rpc)
    log("signer backend: #{signer}")

    %{
      buyer: buyer,
      intent_wallet: intent_wallet,
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

  # -- Signer backends --

  # B (default): Virtuals-delegated Privy signing via the Node sidecar; gas is
  # Alchemy-sponsored. The buyer is the managed SCA agent. Needs (env, from op):
  # RAXOL_ACP_WALLET_ADDRESS / RAXOL_ACP_WALLET_ID / RAXOL_ACP_SIGNER_PRIVATE_KEY
  # (+ PRIVY_APP_ID). The intent is still signed locally as the SCA (EOA -> 1271).
  defp build_signer("privy", from, rpc) do
    _ = fetch_env!("RAXOL_ACP_WALLET_ID")
    _ = fetch_env!("RAXOL_ACP_SIGNER_PRIVATE_KEY")
    address = fetch_env!("RAXOL_ACP_WALLET_ADDRESS")

    start_sidecar!()

    provider =
      ProviderAdapter.Privy.new(
        sidecar_url: Raxol.Earn.SignerSidecar.base_url([]),
        address: address,
        chains: %{from => rpc}
      )

    # The 7702 buyer's ONLY authorized signer is its own managed authority, so the
    # intent (and origin-pull) signature must be produced by the sidecar, not a
    # local session key. Sma7702Wallet resolves this provider at call time.
    :persistent_term.put({__MODULE__, :privy_provider}, provider)

    {provider, address, Sma7702Wallet}
  end

  # A (--signer sca): direct ERC-4337 -- the EOA session key signs UserOps,
  # submitted to your own bundler + paymaster. Needs ORDER_BUNDLER_URL (and
  # ORDER_PAYMASTER_POLICY for sponsorship, else the SCA must hold ETH).
  defp build_signer("sca", from, rpc) do
    bundler = fetch_env!("ORDER_BUNDLER_URL")
    policy = System.get_env("ORDER_PAYMASTER_POLICY")

    provider =
      ProviderAdapter.SCA.new(
        wallet: ScaWallet,
        chains: %{from => rpc},
        wallet_opts: [bundler_url: bundler, paymaster_policy_id: policy]
      )

    {provider, @sca_account, ScaWallet}
  end

  # EOA (--signer eoa): raw EOA. NOT a registered agent, so createJob works but
  # send_message 404s -- kept for on-chain-only testing.
  defp build_signer("eoa", from, rpc) do
    provider =
      ProviderAdapter.JSONRPC.new(
        chains: %{from => rpc},
        private_key: decode_key(fetch_env!("ORDER_KEY"))
      )

    {provider, Signer.address(), Signer}
  end

  defp build_signer(other, _from, _rpc),
    do: Mix.raise("unknown --signer #{inspect(other)} (want privy | sca | eoa)")

  # The managed Privy provider is runtime state; Sma7702Wallet resolves it here at
  # call time so the wallet stays a plain behaviour module.
  @doc false
  @spec privy_provider() :: Raxol.Earn.ProviderAdapter.adapter()
  def privy_provider, do: :persistent_term.get({__MODULE__, :privy_provider})

  # The buyer signs the Xochi intent with the same ORDER_KEY the provider adapter uses.
  # The EOA session key (0x10910...) -- signs on behalf of the SCA agent.
  defmodule Signer do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "ORDER_KEY"
  end

  # The managed SCA agent (0x468a... "testing agent") as a DEPLOYED Modular
  # Account v2 (the --signer sca path): the intent is signed by the session key
  # through the installed single-signer validation module.
  defmodule ScaWallet do
    @moduledoc false
    use Raxol.Earn.Wallet.SCA,
      account_address: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      chain_id: 8453,
      signer: Signer,
      signer_entity_id: 0
  end

  # The managed SCA agent as an EIP-7702 Semi-Modular Account (the default --signer
  # privy path): the intent is signed AS the account by its managed authority via
  # the Privy sidecar, wrapped for the account's native ERC-1271 fallback path. A
  # local session key is NOT an authorized signer on a 7702 account.
  defmodule Sma7702Wallet do
    @moduledoc false
    use Raxol.Earn.Wallet.Sma7702,
      account_address: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      chain_id: 8453,
      provider: {Mix.Tasks.RaxolEarn.Order, :privy_provider}
  end

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

  # A bare `{:ok, _} =` here reported a transport failure as a MatchError on a
  # Req struct, which reads like a Xochi outage. It is more often the local
  # network: some ISPs null-route whole Cloudflare ranges, and api.xochi.fi
  # resolves into one (188.114.96.0/20). Observed on Vodafone ES -- port 80 is
  # intercepted with an "Acceso bloqueado" page and 443 is dropped, so every
  # request dies at connect with no HTTP status to explain itself.
  defp sign_intent_error(%{__struct__: Req.TransportError, reason: reason}) do
    """
    could not reach the Xochi API (transport #{inspect(reason)}).

    This is usually the network path, not Xochi. Check, in order:

      nc -z api.xochi.fi 443          # dropped => blocked upstream, not down
      curl -sI http://api.xochi.fi    # a non-Cloudflare page here => intercepted
      curl -s "https://r.jina.ai/https://xochi.fi"   # answers => the API is fine

    A control host only proves anything if it shares the blocked IP range;
    cloudflare.com and other Cloudflare sites sit elsewhere and will pass while
    this one fails. Route around it with a VPN or an exit node in another
    country. Confirm from off-network before reporting an outage upstream.
    """
  end

  defp sign_intent_error(reason),
    do: "could not sign the Xochi intent: #{inspect(reason)}"

  # `Assets.address/2` answers a bare `:error` for an unsupported pair, so a
  # bad --corridor used to surface as `no match of right hand side value: :error`
  # with no hint of which side was wrong.
  defp usdc_address!(chain_id, side) do
    case Assets.address(chain_id, "USDC") do
      {:ok, address} ->
        address

      :error ->
        supported =
          Assets.supported_chain_ids()
          |> Enum.map(&"#{&1} (#{Assets.chain_name(&1)})")
          |> Enum.join(", ")

        Mix.raise("""
        no USDC address for the #{side} chain #{chain_id}.

        Check --corridor (origin>destination). Chains with a USDC address:
          #{supported}
        """)
    end
  end

  # The sidecar is a Node process: it fails when node is missing, its deps are
  # not installed, the port is taken, or the Privy credentials are rejected.
  # Each of those used to arrive as a MatchError on a start_link tuple.
  defp start_sidecar!() do
    case Raxol.Earn.SignerSidecar.start_link([]) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Mix.raise("""
        the Privy signer sidecar did not start: #{inspect(reason)}

        It is a Node process under packages/raxol_earn/priv/signer_sidecar.
        Check, in order:

          node --version                       # must be present on PATH
          ls priv/signer_sidecar/node_modules  # run `npm install` there if absent
          lsof -i :4048                        # default port, must be free

        RAXOL_ACP_WALLET_ADDRESS / RAXOL_ACP_WALLET_ID / RAXOL_ACP_SIGNER_PRIVATE_KEY
        must all be set: the sidecar reads them at boot and exits if any is missing.
        """)
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
