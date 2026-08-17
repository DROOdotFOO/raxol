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
       settlement proceeds. The provider writes that budget, so `--fund` refuses
       anything above the `--fee-bps` take-rate unless `--max-escrow` raises the
       ceiling.

  ## Signer backends (`--signer`)

  The buyer must be a REGISTERED Virtuals agent to post messages, so the default
  drives a managed SCA agent:

    * `privy` (default) -- Virtuals-delegated signing via the Node signer sidecar
      (`priv/signer_sidecar`). No ETH needed, but gas is NOT free: an ERC-20
      paymaster fronts the ETH and charges the buyer in USDC on every UserOp
      (~0.0075 observed on Base). The buyer is the managed SCA at
      `RAXOL_ACP_WALLET_ADDRESS`; the intent is signed by the account's own
      managed authority (`Sma7702Wallet` -> ERC-1271), not by a session key.
    * `sca` -- direct ERC-4337: the `ORDER_KEY` session key signs UserOps submitted
      to your own bundler + paymaster (`ORDER_BUNDLER_URL`, `ORDER_PAYMASTER_POLICY`).
    * `eoa` -- raw EOA from `ORDER_KEY`. NOT a registered agent (messaging 404s);
      on-chain-only testing.

  MOVES REAL FUNDS. Every non-`--dry-run` run spends USDC, because each UserOp pays
  its own gas in USDC. `--fund` adds the fee escrow: `fee_bps` of the principal,
  ~0.0024 USDC at the 3.00/8bps default.

  The PRINCIPAL does not move in this task's writes. The signed intent only
  AUTHORIZES the solver to pull up to that much during settlement, so a "3.00 USDC"
  run costs ~0.0169 end to end, not 3.00. The task prints a spend plan before it
  does anything -- including under `--dry-run`, which is the mode you want the
  plan in -- and receipt-derived actuals after each write.

  `--dry-run` stops after signing and spends nothing.

  ## Origin pull: the `--solver` pin

  The signed intent carries an origin-pull authorization letting the solver collect
  the principal at settlement. A smart-account buyer (the `privy`/`sca` signers)
  pulls USDC through Permit2, where an EOA buyer pulls the same USDC through
  ERC-3009 -- so the rail comes from the served quote's `payment_method`, never
  from the token.

  That distinction decides how much the destination is bounded. ERC-3009 names the
  recipient inside the signed digest and the token enforces `msg.sender == to`;
  Permit2 has no on-chain recipient guard at all, so the spender picks the
  recipient at call time and the pinned spender is the ONLY destination control.
  A Permit2 quote is therefore refused before signing unless `--solver`
  (or `ORDER_SOLVER`) names the spender AND the quote served exactly it.

  When the pin holds, the run grants the Permit2 allowance first, as one extra
  write: a USDC-gas UserOp under `privy`/`sca`, an ETH-gas tx under `eoa`. The
  approve is for exactly this intent's authorized pull, not a standing max, so a
  later bad signature cannot reach more of the origin balance than this run was
  already spending. It is idempotent: an allowance that already covers the pull
  sends nothing. `--dry-run` reads the allowance and reports whether a funded run
  would need the approve, without sending it.

  ## Env

      ORDER_KEY          session-key EOA (0x-hex): signs the intent, and -- under
                         sca/eoa -- the on-chain txs.
      ORDER_RPC_8453     Base JSON-RPC (reads; eoa/sca broadcast). Default: mainnet.
      ORDER_XOCHI_TOKEN  Xochi Member token.  ORDER_XOCHI_URL default api.xochi.fi.
      ORDER_SOLVER       origin-pull spender to pin, when not passed as --solver.

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
      --solver 0x..      the origin-pull spender to pin (or ORDER_SOLVER). REQUIRED
                         when the quote pulls via Permit2 -- see below.
      --fee-bps N        expected take-rate to assert (default 8).
      --max-escrow N     ceiling in USDC on what --fund will pay. Defaults to the
                         --fee-bps take-rate; a larger on-chain budget is refused.
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

  alias Raxol.Earn.Xochi.OriginPull
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

  @switches [
    amount: :string,
    corridor: :string,
    provider: :string,
    solver: :string,
    fee_bps: :integer,
    max_escrow: :string,
    fund: :boolean,
    dry_run: :boolean,
    job_id: :integer,
    signer: :string
  ]

  @impl Mix.Task
  def run(argv) do
    opts = parse_argv(argv)

    Application.ensure_all_started(:raxol_earn)

    cfg = build_config(opts)
    pin_origin_pull(cfg.solver)

    log(
      "buyer=#{cfg.buyer}  provider=#{cfg.provider}  corridor=#{cfg.from}->#{cfg.to}  amount=#{cfg.amount} USDC"
    )

    # Before anything, including under --dry-run: rehearsing a run is the reason
    # the plan exists, so the costless mode must be the one that shows it.
    print_plan(cfg, opts)

    # 1. Quote, settle the origin-pull allowance, then sign (all off-chain bar the
    #    Permit2 approve).
    bundle =
      case sign_intent(cfg, opts) do
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

  @doc false
  # Public only so the spend gate can be exercised against the flags an operator
  # really types, rather than a hand-built keyword list that could drift from
  # @switches.
  @spec parse_argv([String.t()]) :: keyword()
  def parse_argv(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: @switches)
    opts
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

    # 5. Watch the provider set the budget on-chain and enforce the take-rate.
    budget = await_budget(cfg, job_id)
    realized_bps = Float.round(budget / cfg.principal_atomic * 10_000, 3)
    funding? = Keyword.get(opts, :fund, false)

    log("provider setBudget = #{budget} base units (#{realized_bps} bps)")
    enforce_budget!(cfg, budget, opts)

    log("job #{job_id} is live -- view it at https://app.virtuals.io/acp")

    if funding?, do: fund_job(cfg, job_id, budget)
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
    report_actuals(cfg, "createJob", tx)

    job_id = await_job_id(resolver, cfg, tx)
    log("jobId: #{job_id}")
    job_id
  end

  # approve (USDC) + fund (ACP Core) batched into ONE UserOp, per acp-node-v2. The
  # Virtuals paymaster refuses a standalone approve to a token contract; batched
  # with the ACP-core fund call it accepts the UserOp and bills the buyer in USDC.
  defp fund_job(cfg, job_id, budget) do
    log(funding_line(job_id))

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
        report_actuals(cfg, "approve+fund", txs)

      err ->
        Mix.raise("fund failed: #{inspect(err)}")
    end
  end

  @doc false
  # Public only so the wording can be tested: this line used to call the UserOp
  # sponsored, contradicting the plan printed a few lines earlier in the same run.
  @spec funding_line(non_neg_integer()) :: String.t()
  def funding_line(job_id),
    do:
      "funding escrow: batched approve + fund(#{job_id}) in one UserOp -- " <>
        "gas billed to the buyer in USDC"

  # -- Spend accounting --

  # What this run CAN spend, printed before anything else happens. Every line is a
  # bound or an expectation; actuals come from receipts afterwards.
  #
  # The principal is the trap. It is AUTHORIZED by the signed intent and pulled
  # later by the solver during settlement -- it does not move in this task's
  # writes. Reporting it as escrow overstates a $3.00 run by ~175x.
  defp print_plan(cfg, opts) do
    cfg
    |> spend_plan_lines(opts, resume_escrow(cfg, opts))
    |> Enum.each(&log/1)
  end

  # --amount and --fee-bps describe a job this run CREATES. On --job-id they
  # describe nothing: whoever created that job set its budget. Read it instead of
  # printing an expectation derived from flags the resumed job never saw.
  defp resume_escrow(cfg, opts) do
    with job_id when not is_nil(job_id) <- Keyword.get(opts, :job_id),
         {:ok, budget} <- read_budget(cfg, job_id) do
      {:ok, budget}
    else
      nil -> :new_job
      :not_ready -> :unreadable
    end
  end

  @doc false
  # Public only so it can be tested: the escrow arithmetic, the enforced ceiling
  # and the wording of the principal line are what this exists to get right.
  @spec spend_plan_lines(map(), keyword(), :new_job | :unreadable | {:ok, non_neg_integer()}) ::
          [String.t()]
  def spend_plan_lines(cfg, opts, escrow) do
    decimals = Assets.decimals(cfg.from, cfg.src_token)

    ["SPEND PLAN -- buyer #{cfg.buyer} on chain #{cfg.from}, amounts in USDC"] ++
      escrow_lines(cfg, decimals, escrow_ceiling(cfg, opts), escrow) ++
      [
        "  gas         #{gas_note(cfg.signer)}",
        "             writes this run: #{writes(opts)}"
      ] ++
      permit2_lines(cfg, Keyword.get(opts, :dry_run, false)) ++
      [
        "  principal   #{cfg.amount} AUTHORIZED, not moved here -- the signed intent lets " <>
          "the solver pull up to that during settlement"
      ] ++ plan_footer(opts)
  end

  # `eoa` broadcasts plain EIP-1559 txs and pays ETH; the smart-account signers go
  # through an ERC-20 paymaster that fronts the ETH and bills USDC. Saying "USDC
  # gas" for all three would make the plan wrong for exactly the signer whose gas
  # this task cannot see in its own USDC accounting.
  defp gas_note("eoa"),
    do:
      "paid in ETH by the buyer EOA, NOT in USDC and NOT free; priced per tx, " <>
        "known only from the receipt"

  defp gas_note(_signer),
    do:
      "charged in USDC from the buyer by an ERC-20 paymaster, NOT in ETH " <>
        "and NOT free; priced per UserOp, known only from the receipt"

  # The origin-pull rail is only known once the quote is served, so the approve is
  # conditional -- but it can fire on ANY non-dry run, including one that neither
  # creates nor funds a job, so it is counted as a leg rather than mentioned in
  # passing.
  defp permit2_lines(cfg, false = _dry_run?) do
    [
      "  permit2     +1 approve(Permit2) #{write_noun(cfg.signer)}, gas again, IF the quote's " <>
        "origin pull is Permit2 and the buyer's allowance is short",
      "             approves exactly the intent's authorized pull, not a standing max",
      "             spender pin: #{spender_pin(cfg)}"
    ]
  end

  defp permit2_lines(cfg, true) do
    [
      "  permit2     no approve(Permit2) #{write_noun(cfg.signer)} is sent under --dry-run; the " <>
        "run reads the allowance and reports whether a funded run would need one",
      "             spender pin: #{spender_pin(cfg)}"
    ]
  end

  defp write_noun("eoa"), do: "tx"
  defp write_noun(_signer), do: "UserOp"

  defp spender_pin(%{solver: nil}),
    do:
      "NONE -- a Permit2 pull is refused before signing (pass --solver 0x.. / ORDER_SOLVER); " <>
        "Permit2 has no on-chain recipient guard, so the pin is the only destination control"

  defp spender_pin(%{solver: solver}), do: solver

  defp escrow_lines(cfg, decimals, ceiling, :new_job) do
    [
      "  escrow     ~#{Assets.to_human(expected_escrow(cfg), decimals)} expected " <>
        "(#{cfg.fee_bps} bps of #{cfg.amount}) -> ACP Core #{cfg.core}",
      "             the PROVIDER sets the real budget on-chain; --fund pays what it set, " <>
        ceiling_note(ceiling, decimals)
    ]
  end

  defp escrow_lines(cfg, decimals, ceiling, {:ok, budget}) do
    [
      "  escrow      #{Assets.to_human(budget, decimals)} ON-CHAIN -- the resumed job's own " <>
        "budget -> ACP Core #{cfg.core}",
      "             --amount/--fee-bps do not describe a resumed job; --fund pays it, " <>
        ceiling_note(ceiling, decimals)
    ]
  end

  defp escrow_lines(cfg, decimals, ceiling, :unreadable) do
    [
      "  escrow      UNKNOWN -- could not read the resumed job's budget on chain #{cfg.from}",
      "             --amount/--fee-bps do not describe a resumed job; --fund pays what the " <>
        "provider set, " <> ceiling_note(ceiling, decimals)
    ]
  end

  defp ceiling_note(ceiling, decimals),
    do:
      "refusing anything above #{Assets.to_human(ceiling, decimals)} (raise it with --max-escrow)"

  # Every leg that can broadcast, in the order it happens. The Permit2 approve is
  # first because it is settled before the intent is signed, and it is counted
  # even though the quote decides it: a leg that "usually" does not fire is still
  # a write this run may make, and the plan exists so no write is unannounced.
  defp writes(opts), do: describe_writes(Keyword.get(opts, :dry_run, false), opts)

  defp describe_writes(true, _opts), do: "none (--dry-run writes nothing on-chain)"

  defp describe_writes(false, opts) do
    [
      "approve(Permit2) if the pull needs it",
      if(Keyword.get(opts, :job_id), do: nil, else: "createJob"),
      if(Keyword.get(opts, :fund, false), do: "approve+fund", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp plan_footer(opts) do
    footer(
      Keyword.get(opts, :dry_run, false),
      Keyword.get(opts, :fund, false),
      Keyword.get(opts, :job_id) != nil
    )
  end

  defp footer(true, _funding?, _resuming?),
    do: ["  (--dry-run: signs the intent and stops, spends nothing)"]

  defp footer(false, true, _resuming?), do: []

  defp footer(false, false, false),
    do: ["  (no --fund: no escrow this run, but the createJob write still costs gas)"]

  defp footer(false, false, true),
    do: [
      "  (no --fund and no createJob: the only write this run can make is the " <>
        "conditional approve(Permit2))"
    ]

  defp expected_escrow(cfg), do: div(cfg.principal_atomic * cfg.fee_bps, 10_000)

  # The most --fund may pay. Default: the take-rate the operator asserted with
  # --fee-bps, so a provider that writes a bigger budget on-chain cannot be paid
  # without the operator naming the number.
  defp escrow_ceiling(cfg, opts) do
    case Keyword.get(opts, :max_escrow) do
      nil -> expected_escrow(cfg)
      human -> parse_max_escrow(human, Assets.decimals(cfg.from, cfg.src_token))
    end
  end

  defp parse_max_escrow(human, decimals) do
    case Decimal.parse(human) do
      {value, ""} ->
        Assets.to_atomic(value, decimals)

      _ ->
        Mix.raise("--max-escrow #{inspect(human)} is not a USDC amount (e.g. --max-escrow 0.05)")
    end
  end

  @doc false
  # Public only so the whole gate -- ceiling, verdict and the --fund branch --
  # can be exercised from parsed options without an on-chain run.
  @spec enforce_budget!(map(), non_neg_integer(), keyword()) :: :ok
  def enforce_budget!(cfg, budget, opts) do
    cfg
    |> budget_verdict(budget, escrow_ceiling(cfg, opts))
    |> act_on_verdict(Keyword.get(opts, :fund, false))
  end

  defp act_on_verdict({:ok, line}, _funding?), do: log(line)

  # An over-ceiling budget only threatens a run that would escrow it. Without
  # --fund nothing is approved, so the mismatch is disclosure rather than cause
  # to abandon a job that is already on chain.
  defp act_on_verdict({:error, message}, false), do: log("WARN: " <> message)
  defp act_on_verdict({:error, message}, true), do: Mix.raise(message)

  @doc false
  # Public only so the ceiling decision can be tested without an on-chain run.
  @spec budget_verdict(map(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def budget_verdict(cfg, budget, ceiling) do
    expected = expected_escrow(cfg)

    cond do
      budget == expected ->
        {:ok, "OK: budget == #{cfg.fee_bps} bps of the principal"}

      budget <= ceiling ->
        {:ok,
         "budget #{budget} != expected #{expected} (#{cfg.fee_bps} bps), " <>
           "within the ceiling #{ceiling}"}

      true ->
        {:error,
         "provider set budget #{budget} base units, above the #{ceiling} ceiling -- " <>
           "refusing to fund. The budget is what --fund approves and escrows, so a " <>
           "provider that sets its own number is simply paid it. Either the offering's " <>
           "fee changed, in which case re-run with a matching --fee-bps, or this " <>
           "provider is not charging what it advertises. The ceiling is #{cfg.fee_bps} " <>
           "bps of --amount #{cfg.amount}; on --job-id it does not describe the resumed " <>
           "job at all. Accept this budget with --max-escrow <USDC>."}
    end
  end

  # What actually moved, decoded from receipts. Only USDC transfers OUT of the
  # buyer count as spend; anything else in the tx is someone else's money.
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  defp report_actuals(cfg, label, tx_hashes) do
    client = Raxol.Earn.Onchain.RPC.client(url: cfg.rpc)

    reads =
      tx_hashes
      |> List.wrap()
      |> Enum.map(&{&1, buyer_transfers(client, cfg, &1)})

    Enum.each(spend_actual_lines(cfg, label, reads), &log/1)
  rescue
    # Accounting must never take down a run that already moved money.
    e -> log("SPEND ACTUAL (#{label}): could not read receipts (#{Exception.message(e)})")
  end

  @doc false
  # Public only so it can be tested. A receipt that could NOT be read must not
  # read like a receipt that showed nothing: the first is an unknown, the second
  # is a zero, and printing them the same way is how a real spend gets reported
  # as no spend.
  @spec spend_actual_lines(map(), String.t(), [
          {String.t(), {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}}
        ]) :: [String.t()]
  def spend_actual_lines(cfg, label, reads) do
    decimals = Assets.decimals(cfg.from, cfg.src_token)
    {read, failed} = Enum.split_with(reads, &match?({_hash, {:ok, _}}, &1))
    transfers = Enum.flat_map(read, fn {_hash, {:ok, transfers}} -> transfers end)

    headline(label, decimals, transfers, failed) ++
      Enum.map(transfers, fn {to, amount} ->
        "  #{Assets.to_human(amount, decimals)} -> #{to}#{destination_note(cfg, to)}"
      end) ++
      Enum.map(failed, fn {hash, {:error, reason}} ->
        "  UNREAD receipt #{hash} (#{inspect(reason)}) -- check #{explorer(cfg.from)}#{hash}"
      end)
  end

  defp headline(label, _decimals, [], []),
    do: ["SPEND ACTUAL (#{label}): no USDC left the buyer"]

  defp headline(label, decimals, transfers, []) do
    [
      "SPEND ACTUAL (#{label}): #{Assets.to_human(total(transfers), decimals)} USDC left the buyer"
    ]
  end

  defp headline(label, decimals, transfers, failed) do
    [
      "SPEND ACTUAL (#{label}): at least #{Assets.to_human(total(transfers), decimals)} USDC " <>
        "left the buyer -- LOWER BOUND, #{length(failed)} receipt(s) unread"
    ]
  end

  defp total(transfers), do: transfers |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp buyer_transfers(client, cfg, tx_hash) do
    case Raxol.Earn.Onchain.RPC.await_receipt(client, tx_hash, timeout_ms: 20_000) do
      {:ok, %{"logs" => logs}} when is_list(logs) ->
        buyer_topic = pad_topic(cfg.buyer)

        transfers =
          for %{"address" => addr, "topics" => [topic0, from, to | _], "data" => data} <- logs,
              String.downcase(addr) == String.downcase(cfg.src_token),
              String.downcase(topic0) == @transfer_topic,
              String.downcase(from) == buyer_topic do
            {"0x" <> String.slice(to, -40, 40), parse_uint(data)}
          end

        {:ok, transfers}

      {:ok, other} ->
        {:error, {:receipt_without_logs, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The ERC-20 paymaster that fronts the ETH for the Virtuals-managed SCA and
  # bills the buyer in USDC, observed across four UserOps on Base. Anything else
  # is money going somewhere nobody planned, and must not read as routine gas.
  @paymaster "0x5d74bdab1ce9ddadd7e2e333d1d173830860694a"

  defp destination_note(cfg, to) do
    core = String.downcase(cfg.core)

    case String.downcase(to) do
      ^core -> "  (ACP Core -- the fee escrow)"
      @paymaster -> "  (gas: ERC-20 paymaster)"
      _ -> "  (UNEXPECTED recipient -- neither the fee escrow nor the known paymaster)"
    end
  end

  defp pad_topic("0x" <> addr),
    do: String.downcase("0x" <> String.duplicate("0", 24) <> addr)

  defp parse_uint("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_uint(_), do: 0

  # -- Steps --

  # Quote first, so the origin-pull rail is read from what the solver actually
  # served rather than assumed from the token, then hold the allowance that rail
  # needs BEFORE releasing a signature over it.
  defp sign_intent(cfg, opts) do
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

    with {:ok, quote_resp} <- XochiProtocol.get_quote(cfg.xochi_config, request),
         :ok <- settle_origin_pull(cfg, quote_resp, opts) do
      XochiProtocol.sign_intent(quote_resp, cfg.intent_wallet, request)
    end
  end

  # The Permit2 rail pulls through a standing ERC-20 allowance, which the buyer
  # grants with one extra UserOp. Refusing an unpinned spender happens here,
  # before the approve and before the signature -- an allowance towards an
  # unverified spender is the failure this whole path exists to prevent.
  defp settle_origin_pull(cfg, quote_resp, opts) do
    with {:ok, plan} <- OriginPull.allowance_plan(quote_resp, cfg.solver, origin_leg(cfg)),
         {:ok, outcome} <- ensure_allowance(cfg, plan, opts) do
      log(OriginPull.describe(outcome))
      report_approve(cfg, outcome)
      :ok
    else
      {:error, reason} -> {:error, {:origin_pull, reason}}
    end
  end

  # The transfer the operator asked for. The served permit is cross-checked
  # against it, so the allowance is granted on the chain and token this run named
  # and never exceeds the principal it was told to send.
  defp origin_leg(cfg),
    do: %{chain_id: cfg.from, token: cfg.src_token, amount: cfg.principal_atomic}

  defp ensure_allowance(cfg, plan, opts) do
    OriginPull.ensure_allowance(plan, cfg.provider_adapter, cfg.buyer,
      dry_run: Keyword.get(opts, :dry_run, false)
    )
  end

  defp report_approve(cfg, {:approved, _amount, tx}),
    do: report_actuals(cfg, "permit2 approve", tx)

  defp report_approve(_cfg, _outcome), do: :ok

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

    # `emitter` + `client` scope the JobCreated search to the job THIS buyer
    # created: the sponsored path resolves against a bundle receipt that also
    # carries other senders' JobCreated logs from this same core.
    resolver = %{
      adapter: JobIdResolver.Receipt,
      config: %{
        event_signature: "JobCreated(uint256,address,address,address,uint256,address)",
        topic_index: 1,
        emitter: cfg.core,
        client: cfg.buyer
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

    # Before build_signer, which boots the sidecar: a malformed pin should not
    # cost a subprocess to discover.
    solver = pinned_solver(opts)

    signer = Keyword.get(opts, :signer, "privy")
    {provider_adapter, buyer, intent_wallet} = build_signer(signer, from, rpc)
    log("signer backend: #{signer}")

    %{
      buyer: buyer,
      intent_wallet: intent_wallet,
      provider_adapter: provider_adapter,
      provider: Keyword.get(opts, :provider, @default_provider),
      solver: solver,
      from: from,
      to: to,
      amount: amount,
      principal_atomic: principal_atomic,
      src_token: src_token,
      dst_token: dst_token,
      fee_bps: Keyword.get(opts, :fee_bps, 8),
      signer: signer,
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

  # B (default): Virtuals-delegated Privy signing via the Node sidecar. Gas is not
  # free -- an ERC-20 paymaster fronts the ETH and charges the buyer in USDC per
  # UserOp. The buyer is the managed SCA agent. Needs (env, from op):
  # RAXOL_ACP_WALLET_ADDRESS / RAXOL_ACP_WALLET_ID / RAXOL_ACP_SIGNER_PRIVATE_KEY
  # (+ PRIVY_APP_ID).
  defp build_signer("privy", from, rpc) do
    _ = fetch_env!("RAXOL_ACP_WALLET_ID")
    _ = fetch_env!("RAXOL_ACP_SIGNER_PRIVATE_KEY")
    address = fetch_env!("RAXOL_ACP_WALLET_ADDRESS")
    check_7702_account(String.downcase(address), Sma7702Wallet.address())

    start_sidecar!(address)

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
  # submitted to your own bundler + paymaster. Needs ORDER_BUNDLER_URL and
  # ORDER_PAYMASTER_POLICY: the adapter only ever sends sponsored UserOps,
  # so there is no unsponsored fallback to fall back to.
  # Alchemy multiplexes bundler + gas manager on one URL.
  defp build_signer("sca", from, rpc) do
    bundler = fetch_env!("ORDER_BUNDLER_URL")
    policy = fetch_env!("ORDER_PAYMASTER_POLICY")

    provider =
      ProviderAdapter.SCA.new(
        wallet: ScaWallet,
        chains: %{from => rpc},
        wallet_opts: [
          bundler_url: bundler,
          paymaster_url: bundler,
          paymaster_policy_id: policy
        ]
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

  # Sma7702Wallet's account is the verifyingContract of the replay-safe EIP-712
  # domain it signs over, so pointing RAXOL_ACP_WALLET_ADDRESS at a different
  # managed wallet signs the wrong account's hash: isValidSignature is called on
  # the payer and rejects, surfacing as an opaque 401 after a sidecar round trip.
  defp check_7702_account(account, account), do: :ok

  defp check_7702_account(given, account) do
    Mix.raise(
      "RAXOL_ACP_WALLET_ADDRESS #{given} is not the 7702 account Sma7702Wallet " <>
        "signs for (#{account}); the intent would be signed over the wrong " <>
        "replay-safe hash"
    )
  end

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
  # passes the anti-drain pin (Riddler #591; same set config/runtime.exs uses),
  # plus the spender this run was told to expect. The mirrored contract set is a
  # checked-in copy of a deployment record, so it is never widened silently: a
  # rotated address has to be named on the command line.
  defp pin_origin_pull(solver) do
    Application.put_env(:raxol_payments, :pull_solver_allowlist, pull_allowlist(solver))
    Application.put_env(:raxol_payments, :pull_require_solver_pin, true)
  end

  defp pull_allowlist(nil), do: PullContracts.pull_recipients()
  defp pull_allowlist(solver), do: Enum.uniq([solver | PullContracts.pull_recipients()])

  # The pinned origin-pull spender: a flag, because it is a per-run counterparty
  # address like --provider, and an env var, because the live-gate runner drives
  # this task entirely through ORDER_*. The flag wins when both are set.
  defp pinned_solver(opts) do
    case Keyword.get(opts, :solver) || System.get_env("ORDER_SOLVER") do
      nil -> nil
      value -> solver_address!(String.trim(value))
    end
  end

  defp solver_address!(""), do: nil

  defp solver_address!(value) do
    case Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, value) do
      true ->
        value

      false ->
        Mix.raise(
          "--solver / ORDER_SOLVER #{inspect(value)} is not a 0x-hex 20-byte address. " <>
            "It pins the origin-pull spender, so a typo would either reject every quote " <>
            "or pin the wrong destination."
        )
    end
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

  defp sign_intent_error({:origin_pull, reason}), do: OriginPull.explain(reason)

  # The pin rejected the served recipient/spender. The addresses it accepts are a
  # checked-in mirror of Riddler's deployment record plus whatever --solver named,
  # so a rotated pull contract lands here rather than anywhere more informative.
  defp sign_intent_error({:authorization_mismatch, field})
       when field in [:pull_to, :pull_spender] do
    """
    the quote's origin-pull recipient is not pinned (#{field}).

    Nothing was signed. The accepted set is the verified XochiPull contracts this
    repo mirrors, plus any --solver / ORDER_SOLVER address. A solver that has
    redeployed its pull contract will fail exactly here: confirm the new address
    against Riddler's XochiPull deployment record, then re-run with

      --solver 0x<spender>

    Do not widen the pin to whatever the quote served -- checking that value is
    the entire point of it.
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
        # Read the table `address/2` reads. `Assets.supported_chain_ids/0` is the
        # union over every symbol, so it also lists chains that carry USDG or WETH
        # but no USDC -- naming those here sends the operator round the same error.
        supported =
          Assets.evm_tokens()
          |> Map.fetch!("USDC")
          |> Map.keys()
          |> Enum.sort()
          |> Enum.map_join(", ", &"#{&1} (#{Assets.chain_name(&1)})")

        Mix.raise("""
        no USDC address for the #{side} chain #{chain_id}.

        Check --corridor (origin>destination). Chains with a USDC address:
          #{supported}
        """)
    end
  end

  # The sidecar is a Node process: it fails when node is missing, its deps are not
  # installed, the port is taken, or the Privy credentials are rejected. A plain
  # `start_link` cannot report any of those here -- the linked child's exit signal
  # kills this task before the return value is read -- so go through the trapping
  # start, which turns the exit back into a reason.
  defp start_sidecar!(address) do
    case Raxol.Earn.SignerSidecar.start_link_or_error(expect_address: address) do
      {:ok, pid} -> pid
      {:error, reason} -> Mix.raise(sidecar_error(reason))
    end
  end

  defp sidecar_error({:sidecar_unhealthy, {:sidecar_wrong_wallet, got, want}}) do
    url = Raxol.Earn.SignerSidecar.base_url([])

    """
    #{url} answers /health for the WRONG wallet: #{got}, expected #{want}.

    Something else already holds that port -- most often a signer sidecar left over
    from an earlier run, delegated to a different agent. Left alone it would sign
    this order's intent and its on-chain calls as #{got}, while every log line here
    said #{want}. Find and stop it:

      lsof -i :#{URI.parse(url).port}

    Or point this run elsewhere with RAXOL_ACP_SIGNER_PORT / RAXOL_ACP_SIDECAR_URL.
    """
  end

  defp sidecar_error(reason) do
    """
    the Privy signer sidecar did not start: #{inspect(reason)}

    It is a Node process under packages/raxol_earn/priv/signer_sidecar.
    Check, in order:

      node --version                       # must be present on PATH
      ls priv/signer_sidecar/node_modules  # run `npm install` there if absent
      lsof -i :4048                        # default port; the sidecar exits if taken

    RAXOL_ACP_WALLET_ADDRESS / RAXOL_ACP_WALLET_ID / RAXOL_ACP_SIGNER_PRIVATE_KEY
    must all be set: the sidecar reads them at boot and exits if any is missing.
    """
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
