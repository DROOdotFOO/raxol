defmodule Raxol.ACP.ContractClient.Onchain do
  @moduledoc """
  Live ACP contract client backed by JSON-RPC.

  Implements the `Raxol.ACP.ContractClient` behaviour by:

  1. Encoding the call data via `Raxol.ACP.ABI`
  2. Building an EIP-1559 transaction (`Raxol.ACP.Onchain.Transaction`)
  3. Querying nonce + fee suggestion + gas estimate via JSON-RPC
     (`Raxol.ACP.Onchain.RPC`)
  4. Hashing the unsigned transaction and asking the configured wallet
     to `sign_hash/1`
  5. Serializing and broadcasting via `eth_sendRawTransaction`
  6. Waiting for the receipt via `eth_getTransactionReceipt`

  Same dispatch pattern as `Raxol.ACP.ContractClient.InMemory`: pick at
  config time.

      config :raxol_acp,
        contract_client: Raxol.ACP.ContractClient.Onchain,
        rpc: [url: "https://sepolia.base.org"],
        chain: :sepolia,
        onchain_wallet: MyApp.Wallet        # any Raxol.Payments.Wallet impl

  ## Two wallet paths (selected by capability)

  - **EOA** (`Raxol.Payments.Wallets.Env`/`Op`): the call is signed as
    an EIP-1559 transaction and broadcast via `eth_sendRawTransaction`.
  - **Smart Contract Account** (`Raxol.ACP.Wallet.SCA`, what Virtuals
    agents use): the call is wrapped in the account's `execute(...)`,
    built into an ERC-4337 UserOperation, sponsored by the Alchemy gas
    manager (gasless), signed by the session key, and submitted to a
    bundler. Detected via `send_sponsored_user_operation/2` so the same
    `:onchain_wallet` slot serves both. The EntryPoint nonce is fetched
    with `getNonce(account, key)`; the job-id / receipt handling below
    is identical -- the bundler receipt embeds the on-chain tx receipt.

  ## Method selectors

  The ACP method selectors below are the **canonical** `ACPSimple`
  signatures, taken from the vendored ABI at
  `priv/abi/acp_simple.json` (extracted from
  `@virtuals-protocol/acp-node`).

  ## Remaining caveat (external, not engineering)

  **`Chain.acp_contract_address` defaults to `nil`.** Calls fail with
  `:no_contract_address` until the deployed ACP contract address is
  configured via `Raxol.ACP.Chain` overrides.

  ## Job ID extraction

  `create_job/3` decodes the new job ID from the `JobCreated` event log
  in the transaction receipt via `Raxol.ACP.Onchain.LogDecoder`. The
  canonical ACPSimple event is
  `JobCreated(uint256 jobId, address client, address provider, address evaluator)`,
  where `jobId` is NON-indexed (in `data`) and the three addresses are
  indexed. So the defaults read `data` word 0 as a `uint256` and return
  it as a hex string (`"0x" <> hex`). Both the event signature and the
  id location are overridable for other ABIs:

      config :raxol_acp,
        create_job_event_signature: "JobCreated(uint256,address,address,address)",
        create_job_id_source: {:data, 0}   # or {:topic, index} for an indexed id

  Fails closed: when the id cannot be resolved (event absent, decode
  error), `create_job/3` returns `{:error, {:job_id_unresolved, reason}}`
  rather than a synthetic id, because a wrong job ID silently mis-targets
  every downstream call. An integration harness whose stub does not emit
  a real `JobCreated` event can opt back into the tx-hash placeholder:

      config :raxol_acp, allow_placeholder_job_id: true

  In that mode the fallback returns the transaction hash as the job ID and
  emits `[:raxol, :acp, :onchain, :placeholder_job_id]`.

  ## Telemetry

  - `[:raxol, :acp, :onchain, :tx_sent]` -- after an EOA broadcast.
    Metadata: `%{method, tx_hash, gas_limit, max_fee_per_gas}`
  - `[:raxol, :acp, :onchain, :user_op_sent]` -- after an SCA bundler
    submission. Metadata: `%{method, user_op_hash, tx_hash}`
  - `[:raxol, :acp, :onchain, :tx_mined]` -- after receipt (both paths).
    Metadata: `%{method, tx_hash, block_number, status}`
  - `[:raxol, :acp, :onchain, :placeholder_job_id]` -- emitted by
    `create_job/3` when no `:create_job_event_signature` is configured
    (or the event is absent from the receipt) and it falls back to the
    tx hash as the job id.
  """

  @behaviour Raxol.ACP.ContractClient

  alias Raxol.ACP.{ABI, Chain}
  alias Raxol.ACP.Onchain.{LogDecoder, RPC, Transaction}
  alias Raxol.ACP.Wallet.NonceServer
  alias Raxol.ACP.Wallet.SCA.{ModularAccount, UserOp}

  @sig_get_nonce "getNonce(address,uint192)"

  # Canonical selectors. Most are identical between V1 ACPSimple
  # (priv/abi/acp_simple.json) and V2 ACPRouter (priv/abi/acp_router.json).
  # `createJob` and `createPayableMemo` differ -- see acp_version/0.
  @sig_create_job "createJob(address,address,uint256)"
  @sig_create_job_v2 "createJob(address,address,uint256,address,uint256,string)"
  @sig_set_budget "setBudget(uint256,uint256)"
  @sig_set_budget_token "setBudgetWithPaymentToken(uint256,uint256,address)"
  @sig_create_memo "createMemo(uint256,string,uint8,bool,uint8)"
  @sig_create_payable_memo "createPayableMemo(uint256,string,address,uint256,address,uint256,uint8,uint8,uint8,uint256)"
  @sig_create_payable_memo_v2 "createPayableMemo(uint256,string,address,uint256,address,uint256,uint8,uint8,uint256,bool,uint8)"
  @sig_sign_memo "signMemo(uint256,bool,string)"
  @sig_claim_budget "claimBudget(uint256)"
  @sig_confirm_x402 "confirmX402PaymentReceived(uint256)"

  # Which deployed ACP contract the selectors target. `:v1` (ACPSimple,
  # default) or `:v2` (ACPRouter). Set the matching contract address via
  # `Raxol.ACP.Chain` overrides when running V2.
  defp acp_version, do: Application.get_env(:raxol_acp, :acp_version, :v1)

  # -- Behaviour callbacks --

  @impl true
  def create_job(provider, evaluator, expired_at)
      when is_binary(provider) and is_binary(evaluator) and is_integer(expired_at) do
    call_data = create_job_calldata(acp_version(), provider, evaluator, expired_at)

    case send_tx(:create_job, call_data) do
      {:ok, tx_hash, receipt} -> resolve_job_id(tx_hash, receipt)
      {:error, _} = err -> err
    end
  end

  defp create_job_calldata(:v1, provider, evaluator, expired_at) do
    ABI.encode_call(@sig_create_job, [
      {"address", provider},
      {"address", evaluator},
      {"uint256", expired_at}
    ])
  end

  # V2 createJob folds payment token + budget + metadata into the call.
  # We default the token to the chain's USDC, budget 0 (set later via
  # `set_budget/2`), and empty metadata -- keeping the create_job/3
  # behaviour stable across versions.
  defp create_job_calldata(:v2, provider, evaluator, expired_at) do
    ABI.encode_call(@sig_create_job_v2, [
      {"address", provider},
      {"address", evaluator},
      {"uint256", expired_at},
      {"address", chain_config().usdc_address},
      {"uint256", 0},
      {"string", ""}
    ])
  end

  @impl true
  def set_budget(job_id, %Decimal{} = amount) when is_binary(job_id) do
    call_data =
      ABI.encode_call(@sig_set_budget, [
        {"uint256", job_id_to_uint256(job_id)},
        {"uint256", decimal_to_uint256(amount)}
      ])

    case send_tx(:set_budget, call_data) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  # Resolve the new jobId from the JobCreated event in the receipt logs.
  #
  # The canonical ACPSimple JobCreated event carries the new uint256 jobId
  # as its first NON-indexed parameter (in `data`), with client/provider/
  # evaluator indexed. So the default reads `data` word 0. Both the event
  # signature and the id source are configurable for other ABIs.
  #
  # Fails closed: if the id cannot be resolved, return an error rather than
  # a synthetic tx-hash id. A tx hash returned as a job id silently
  # mis-targets every downstream call (set_budget, create_memo,
  # claim_budget) at the wrong uint256. An integration harness whose stub
  # does not emit a real JobCreated event can opt back into the tx-hash
  # placeholder with `config :raxol_acp, allow_placeholder_job_id: true`.
  defp resolve_job_id(tx_hash, receipt) do
    signature =
      Application.get_env(
        :raxol_acp,
        :create_job_event_signature,
        default_job_event_signature()
      )

    logs = Map.get(receipt, "logs", [])

    case decode_job_id(logs, signature) do
      {:ok, job_id_int} ->
        {:ok, "0x" <> (job_id_int |> Integer.to_string(16) |> String.downcase())}

      {:error, reason} ->
        resolve_job_id_fallback(tx_hash, reason)
    end
  end

  # ACPSimple JobCreated(uint256 jobId, address client, address provider,
  # address evaluator): jobId non-indexed, the other three indexed.
  defp default_job_event_signature, do: "JobCreated(uint256,address,address,address)"

  defp decode_job_id(_logs, signature) when not is_binary(signature),
    do: {:error, :no_event_signature}

  defp decode_job_id(logs, signature) do
    case Application.get_env(:raxol_acp, :create_job_id_source, {:data, 0}) do
      {:data, word} -> LogDecoder.extract_data(logs, signature, word, :uint256)
      {:topic, index} -> LogDecoder.extract(logs, signature, index, :uint256)
    end
  end

  defp resolve_job_id_fallback(tx_hash, reason) do
    if Application.get_env(:raxol_acp, :allow_placeholder_job_id, false) do
      emit_placeholder(tx_hash, reason)
      {:ok, tx_hash}
    else
      {:error, {:job_id_unresolved, reason}}
    end
  end

  defp emit_placeholder(tx_hash, reason) do
    :telemetry.execute(
      [:raxol, :acp, :onchain, :placeholder_job_id],
      %{},
      %{tx_hash: tx_hash, reason: reason}
    )
  end

  @impl true
  def create_memo(job_id, content, memo_type, is_secured, next_phase)
      when is_binary(job_id) and is_binary(content) and is_atom(memo_type) and
             is_boolean(is_secured) and is_atom(next_phase) do
    memo_type_uint8 = Raxol.ACP.Job.MemoType.to_uint8(memo_type)
    next_phase_uint8 = Raxol.ACP.Job.StateMachine.phase_id(next_phase)

    call_data =
      ABI.encode_call(@sig_create_memo, [
        {"uint256", job_id_to_uint256(job_id)},
        {"string", content},
        {"uint8", memo_type_uint8},
        {"bool", is_secured},
        {"uint8", next_phase_uint8}
      ])

    case send_tx(:create_memo, call_data) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  @impl true
  def sign_memo(memo_id, approved, reason)
      when (is_binary(memo_id) or is_integer(memo_id)) and is_boolean(approved) and
             is_binary(reason) do
    call_data =
      ABI.encode_call(@sig_sign_memo, [
        {"uint256", memo_id_to_uint256(memo_id)},
        {"bool", approved},
        {"string", reason}
      ])

    case send_tx(:sign_memo, call_data) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  @impl true
  def claim_budget(job_id) when is_binary(job_id) do
    call_data = ABI.encode_call(@sig_claim_budget, [{"uint256", job_id_to_uint256(job_id)}])

    case send_tx(:claim_budget, call_data) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  defp memo_id_to_uint256(memo_id) when is_integer(memo_id) and memo_id >= 0, do: memo_id
  defp memo_id_to_uint256(memo_id) when is_binary(memo_id), do: job_id_to_uint256(memo_id)

  @impl true
  def set_budget_with_payment_token(job_id, %Decimal{} = amount, token)
      when is_binary(job_id) and is_binary(token) do
    call_data =
      ABI.encode_call(@sig_set_budget_token, [
        {"uint256", job_id_to_uint256(job_id)},
        {"uint256", decimal_to_uint256(amount)},
        {"address", token}
      ])

    case send_tx(:set_budget_with_payment_token, call_data) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  @impl true
  def confirm_x402_payment_received(job_id) when is_binary(job_id) do
    confirm_x402_payment_received(job_id, acp_version())
  end

  # V1 ACPSimple has `confirmX402PaymentReceived(uint256)`. The V2
  # ACPRouter ABI dropped it -- V2 uses `createX402Job` + the facilitator
  # callback instead. Calling the V1 selector against a V2 router would
  # silently encode garbage, so fail fast.
  defp confirm_x402_payment_received(job_id, :v1) do
    call_data = ABI.encode_call(@sig_confirm_x402, [{"uint256", job_id_to_uint256(job_id)}])

    case send_tx(:confirm_x402_payment_received, call_data) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  defp confirm_x402_payment_received(_job_id, :v2),
    do: {:error, :unsupported_in_v2}

  @impl true
  def create_payable_memo(job_id, content, opts)
      when is_binary(job_id) and is_binary(content) and is_list(opts) do
    {sig, args} = payable_memo_call(acp_version(), job_id, content, opts)

    case send_tx(:create_payable_memo, ABI.encode_call(sig, args)) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  # V1 order ends `..., nextPhase, expiredAt`. V2 inserts `isSecured`
  # and reorders to `..., expiredAt, isSecured, nextPhase`.
  defp payable_memo_call(:v1, job_id, content, opts) do
    args =
      payable_memo_head(job_id, content, opts) ++
        [
          {"uint8", Raxol.ACP.Job.StateMachine.phase_id(Keyword.fetch!(opts, :next_phase))},
          {"uint256", Keyword.get(opts, :expired_at, 0)}
        ]

    {@sig_create_payable_memo, args}
  end

  defp payable_memo_call(:v2, job_id, content, opts) do
    args =
      payable_memo_head(job_id, content, opts) ++
        [
          {"uint256", Keyword.get(opts, :expired_at, 0)},
          {"bool", Keyword.get(opts, :is_secured, false)},
          {"uint8", Raxol.ACP.Job.StateMachine.phase_id(Keyword.fetch!(opts, :next_phase))}
        ]

    {@sig_create_payable_memo_v2, args}
  end

  # The leading 8 args are identical across V1/V2.
  defp payable_memo_head(job_id, content, opts) do
    [
      {"uint256", job_id_to_uint256(job_id)},
      {"string", content},
      {"address", Keyword.fetch!(opts, :token)},
      {"uint256", decimal_to_uint256(Keyword.fetch!(opts, :amount))},
      {"address", Keyword.fetch!(opts, :recipient)},
      {"uint256", decimal_to_uint256(Keyword.get(opts, :fee_amount, Decimal.new(0)))},
      {"uint8", Raxol.ACP.Job.FeeType.to_uint8(Keyword.get(opts, :fee_type, :no_fee))},
      {"uint8", Raxol.ACP.Job.MemoType.to_uint8(Keyword.get(opts, :memo_type, :payable_request))}
    ]
  end

  # -- Send pipeline --

  # Two transaction paths share this entry point:
  #
  #   * EOA wallets (`Wallets.Env`/`Op`) sign an EIP-1559 transaction
  #     and broadcast it directly (`send_with/3`).
  #   * Smart Contract Account wallets (`Raxol.ACP.Wallet.SCA`) wrap the
  #     call in `execute(...)`, build an ERC-4337 UserOperation, sponsor
  #     it via the Alchemy gas manager, sign, and submit to a bundler
  #     (`send_via_sca/3`). Selected by capability so config stays in
  #     the single `:onchain_wallet` slot.
  defp send_tx(method, call_data) do
    with {:ok, ctx} <- build_context() do
      if sca_wallet?(ctx.wallet) do
        send_via_sca(ctx, method, call_data)
      else
        send_with(ctx, method, call_data)
      end
    end
  end

  defp sca_wallet?(wallet), do: function_exported?(wallet, :send_sponsored_user_operation, 2)

  # -- SCA / ERC-4337 path --

  defp send_via_sca(ctx, method, call_data) do
    account = ctx.wallet.address()
    exec_calldata = ModularAccount.execute_calldata(ctx.contract_address, 0, call_data)
    wallet_opts = sca_wallet_opts()

    with {:ok, nonce} <- entrypoint_nonce(ctx, account),
         {:ok, init_code} <- maybe_init_code(ctx, account),
         op = %UserOp{
           sender: account,
           nonce: nonce,
           call_data: exec_calldata,
           init_code: init_code
         },
         {:ok, op_hash} <- ctx.wallet.send_sponsored_user_operation(op, wallet_opts),
         {:ok, uo_receipt} <- ctx.wallet.await_user_operation(op_hash, wallet_opts) do
      finish_sca(method, op_hash, uo_receipt)
    end
  end

  defp finish_sca(method, op_hash, uo_receipt) do
    receipt = Map.get(uo_receipt, "receipt", uo_receipt)
    tx_hash = Map.get(receipt, "transactionHash") || op_hash

    :telemetry.execute(
      [:raxol, :acp, :onchain, :user_op_sent],
      %{},
      %{method: method, user_op_hash: op_hash, tx_hash: tx_hash}
    )

    emit_mined(method, tx_hash, receipt, sca_status(uo_receipt))
    {:ok, tx_hash, receipt}
  end

  defp sca_status(%{"success" => true}), do: :success
  defp sca_status(%{"success" => false}), do: :failure
  defp sca_status(_), do: :unknown

  # On the account's first transaction it isn't deployed yet, so the
  # UserOp must carry the factory `initCode` that self-deploys it. We
  # check `eth_getCode`; once deployed, subsequent ops omit initCode.
  # Requires the wallet to expose `deploy_init_code/0` (SCA wallets do).
  defp maybe_init_code(ctx, account) do
    if function_exported?(ctx.wallet, :deploy_init_code, 0) do
      case RPC.deployed?(ctx.client, account) do
        {:ok, true} -> {:ok, <<>>}
        {:ok, false} -> {:ok, ctx.wallet.deploy_init_code()}
        {:error, _} = err -> err
      end
    else
      {:ok, <<>>}
    end
  end

  # Bundler/paymaster calls normally use the SCA wallet's own configured
  # URLs. Tests inject a stub by setting `:sca_rpc` (a `%Req.Request{}`
  # or a keyword passed to `Req.new/1`), which we thread through as the
  # `:req` opt so both legs hit the stub. Returns `[]` in production.
  defp sca_wallet_opts do
    case Application.get_env(:raxol_acp, :sca_rpc) do
      nil -> []
      %Req.Request{} = req -> [req: req]
      opts when is_list(opts) -> [req: Req.new(opts)]
    end
  end

  # EntryPoint.getNonce(account, key) -> full 256-bit nonce. The key
  # encodes the validating session entity (see ModularAccount.nonce_key).
  defp entrypoint_nonce(ctx, account) do
    key = ctx.wallet.nonce_key()

    call_data =
      ABI.encode_call(@sig_get_nonce, [{"address", account}, {"uint192", key}])

    case RPC.eth_call(ctx.client, %{to: ctx.wallet.entry_point(), data: call_data}) do
      {:ok, hex} -> {:ok, decode_uint256(hex)}
      {:error, _} = err -> err
    end
  end

  defp decode_uint256("0x" <> ""), do: 0
  defp decode_uint256("0x" <> hex), do: String.to_integer(hex, 16)
  defp decode_uint256(_), do: 0

  defp send_with(ctx, method, call_data) do
    with {:ok, nonce} <- nonce(ctx),
         {:ok, max_fee, max_priority} <- fee_suggestion(ctx),
         {:ok, gas_limit} <- estimate_gas(ctx, call_data),
         tx <-
           Transaction.new(
             chain_id: ctx.chain.chain_id,
             nonce: nonce,
             max_priority_fee_per_gas: max_priority,
             max_fee_per_gas: max_fee,
             gas_limit: gas_limit,
             to: ctx.contract_address,
             value: 0,
             data: call_data,
             access_list: []
           ),
         digest <- Transaction.signing_hash(tx),
         {:ok, signature} <- ctx.wallet.sign_hash(digest),
         raw <- Transaction.serialize(tx, signature),
         {:ok, tx_hash} <- RPC.send_raw_transaction(ctx.client, raw) do
      :telemetry.execute(
        [:raxol, :acp, :onchain, :tx_sent],
        %{},
        %{
          method: method,
          tx_hash: tx_hash,
          gas_limit: gas_limit,
          max_fee_per_gas: max_fee
        }
      )

      case RPC.await_receipt(ctx.client, tx_hash, timeout_ms: ctx.receipt_timeout_ms) do
        {:ok, %{"status" => "0x1"} = receipt} ->
          emit_mined(method, tx_hash, receipt, :success)
          {:ok, tx_hash, receipt}

        {:ok, %{"status" => "0x0"} = receipt} ->
          emit_mined(method, tx_hash, receipt, :failure)
          {:error, {:tx_reverted, tx_hash}}

        {:ok, receipt} ->
          # Older RPCs may omit "status"; treat as success but log.
          emit_mined(method, tx_hash, receipt, :unknown)
          {:ok, tx_hash, receipt}

        {:error, reason} ->
          {:error, {:receipt_wait, reason}}
      end
    end
  end

  defp emit_mined(method, tx_hash, receipt, status) do
    block_number =
      case Map.get(receipt, "blockNumber") do
        nil ->
          nil

        hex ->
          case RPC.decode_quantity(hex),
            do: (
              {:ok, n} -> n
              _ -> nil
            )
      end

    :telemetry.execute(
      [:raxol, :acp, :onchain, :tx_mined],
      %{},
      %{
        method: method,
        tx_hash: tx_hash,
        block_number: block_number,
        status: status
      }
    )
  end

  # -- Context builders --

  defp build_context do
    chain = chain_config()

    with {:ok, contract_address} <- contract_address(chain),
         {:ok, wallet} <- wallet_module(),
         {:ok, client} <- {:ok, RPC.client(url: chain.rpc_url)} do
      {:ok,
       %{
         chain: chain,
         contract_address: contract_address,
         wallet: wallet,
         client: client,
         receipt_timeout_ms: Application.get_env(:raxol_acp, :onchain_receipt_timeout_ms, 30_000)
       }}
    end
  end

  defp chain_config do
    case Application.get_env(:raxol_acp, :chain, :mainnet) do
      :mainnet -> Chain.mainnet()
      :sepolia -> Chain.sepolia()
      atom when is_atom(atom) -> raise "unknown chain: #{inspect(atom)}"
    end
  end

  defp contract_address(chain), do: contract_address(chain, acp_version())

  defp contract_address(%{acp_contract_address: nil}, :v1), do: {:error, :no_contract_address}
  defp contract_address(%{acp_contract_address: addr}, :v1), do: {:ok, addr}
  defp contract_address(%{acp_router_address: nil}, :v2), do: {:error, :no_router_address}
  defp contract_address(%{acp_router_address: addr}, :v2), do: {:ok, addr}

  defp wallet_module do
    case Application.get_env(:raxol_acp, :onchain_wallet) do
      nil -> {:error, :no_wallet_configured}
      mod when is_atom(mod) -> {:ok, mod}
    end
  end

  # -- Nonce / fee / gas --

  defp nonce(ctx) do
    address = ctx.wallet.address()

    case NonceServer.peek() do
      n when is_integer(n) and n > 0 ->
        # Local NonceServer has been seeded; trust it.
        {:ok, NonceServer.get_next()}

      _ ->
        # Fall back to chain-side pending nonce on first use.
        case RPC.get_transaction_count(ctx.client, address) do
          {:ok, n} ->
            :ok = NonceServer.reset(n)
            {:ok, NonceServer.get_next()}

          {:error, _} = err ->
            err
        end
    end
  end

  # EIP-1559 fee suggestion: pull the last 4 blocks' base fee +
  # 50th-percentile priority fee, then propose:
  #   max_priority = p50 priority (or 1 gwei if missing)
  #   max_fee      = 2 * latest_base_fee + max_priority
  defp fee_suggestion(ctx) do
    case RPC.fee_history(ctx.client, 4, "latest", [50]) do
      {:ok, %{"baseFeePerGas" => base_fees, "reward" => rewards}} ->
        latest_base_fee = base_fees |> List.last() |> hex_to_int()
        priority = priority_from_rewards(rewards)
        max_fee = latest_base_fee * 2 + priority
        {:ok, max_fee, priority}

      {:ok, _} ->
        {:error, :malformed_fee_history}

      {:error, _} = err ->
        err
    end
  end

  defp priority_from_rewards(rewards) when is_list(rewards) and rewards != [] do
    rewards
    |> Enum.flat_map(& &1)
    |> Enum.map(&hex_to_int/1)
    |> Enum.max(fn -> 1_000_000_000 end)
  end

  defp priority_from_rewards(_), do: 1_000_000_000

  defp hex_to_int(hex) do
    case RPC.decode_quantity(hex) do
      {:ok, n} -> n
      _ -> 0
    end
  end

  defp estimate_gas(ctx, call_data) do
    tx = %{
      from: ctx.wallet.address(),
      to: ctx.contract_address,
      data: call_data
    }

    case RPC.estimate_gas(ctx.client, tx) do
      {:ok, n} -> {:ok, with_buffer(n)}
      {:error, _} = err -> err
    end
  end

  # 25% gas buffer to absorb fluctuations between estimate and execution.
  defp with_buffer(n), do: div(n * 5, 4)

  # -- Conversions --

  defp decimal_to_uint256(%Decimal{} = d) do
    # USDC is 6 decimals on Base.
    d
    |> Decimal.mult(Decimal.new(1_000_000))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp job_id_to_uint256(job_id) when is_binary(job_id) do
    # Job ids are hex uint256 when LogDecoder resolved a real JobCreated
    # event, or the tx hash when it fell back (see the placeholder_job_id
    # caveat in the moduledoc). Both parse cleanly here; opaque InMemory
    # ids hash into 32 bytes so the pipeline still works under tests.
    case parse_uint256(job_id) do
      {:ok, n} ->
        n

      :error ->
        # Hash the opaque string into 32 bytes and treat as uint256.
        # This is non-canonical but lets the rest of the pipeline work
        # against placeholder job ids during integration.
        <<n::256>> = ExKeccak.hash_256(job_id)
        n
    end
  end

  defp parse_uint256("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_uint256(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end
end
