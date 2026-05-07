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
        wallet: MyApp.Wallet                # any Raxol.Payments.Wallet impl

  ## v0.1 caveats (documented; not bugs)

  These three are blocked on external work, not engineering:

  1. **Solidity signatures are placeholders.** The four ACP method
     selectors below are best-guess shapes. Once Virtuals' real ABIs
     are vendored in `priv/abi/`, swap these constants. The encoders,
     signing, and broadcast pipeline don't change.
  2. **No event-log decoding for `create_job`.** The real ACP contract
     emits a `JobCreated(uint256 jobId, ...)` event whose first
     indexed topic is the new job ID. Until we have that ABI, this
     impl returns the **transaction hash** as the synthetic job ID
     and emits a telemetry warning. A `LogDecoder` follow-up will
     swap in the real decode.
  3. **`Chain.acp_contract_address` defaults to `nil`.** Calls will
     fail with `:no_contract_address` until a real address is
     configured via `Raxol.ACP.Chain` overrides.

  ## Telemetry

  - `[:raxol, :acp, :onchain, :tx_sent]` -- after broadcast.
    Metadata: `%{method, tx_hash, gas_limit, max_fee_per_gas}`
  - `[:raxol, :acp, :onchain, :tx_mined]` -- after receipt.
    Metadata: `%{method, tx_hash, block_number, status}`
  - `[:raxol, :acp, :onchain, :placeholder_job_id]` -- emitted by
    `create_job/3` while the LogDecoder TODO is open.
  """

  @behaviour Raxol.ACP.ContractClient

  alias Raxol.ACP.{ABI, Chain}
  alias Raxol.ACP.Onchain.{RPC, Transaction}
  alias Raxol.ACP.Wallet.NonceServer

  # Placeholder signatures. Replace when Virtuals ABIs are vendored.
  @sig_create_job "createJob(address,uint256,bytes)"
  @sig_submit_memo "submitMemo(uint256,uint8,bytes,bytes)"
  @sig_complete_job "completeJob(uint256,bytes32)"
  @sig_pay_and_accept "payAndAcceptRequirement(uint256,bytes)"

  # Memo type indexing matches the ACP state machine ordering.
  @memo_type_index %{
    request: 0,
    negotiation: 1,
    transaction: 2,
    evaluation: 3,
    completed: 4,
    expired: 5
  }

  # -- Behaviour callbacks --

  @impl true
  def create_job(seller, %Decimal{} = price_usdc, data)
      when is_binary(seller) and is_binary(data) do
    call_data =
      ABI.encode_call(@sig_create_job, [
        {"address", seller},
        {"uint256", decimal_to_uint256(price_usdc)},
        {"bytes", data}
      ])

    case send_tx(:create_job, call_data) do
      {:ok, tx_hash, _receipt} ->
        :telemetry.execute(
          [:raxol, :acp, :onchain, :placeholder_job_id],
          %{},
          %{tx_hash: tx_hash}
        )

        {:ok, tx_hash}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def submit_memo(job_id, memo_type, payload, signature)
      when is_binary(job_id) and is_atom(memo_type) and is_map(payload) and
             is_binary(signature) do
    type_idx =
      Map.get(@memo_type_index, memo_type) ||
        raise ArgumentError, "unknown memo type: #{inspect(memo_type)}"

    payload_bytes = Jason.encode!(payload)

    call_data =
      ABI.encode_call(@sig_submit_memo, [
        {"uint256", job_id_to_uint256(job_id)},
        {"uint256", type_idx},
        {"bytes", payload_bytes},
        {"bytes", signature}
      ])

    case send_tx(:submit_memo, call_data) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  @impl true
  def complete_job(job_id, deliverable_hash)
      when is_binary(job_id) and is_binary(deliverable_hash) do
    call_data =
      ABI.encode_call(@sig_complete_job, [
        {"uint256", job_id_to_uint256(job_id)},
        {"bytes32", to_hex_bytes32(deliverable_hash)}
      ])

    case send_tx(:complete_job, call_data) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  # ABI's bytes32 encoder takes a hex string. Accept either:
  #   - raw 32-byte binary -> hex-encode
  #   - 0x-prefixed 64-char hex -> pass through
  #   - bare 64-char hex -> pass through
  defp to_hex_bytes32(<<bytes::binary-size(32)>>),
    do: "0x" <> Base.encode16(bytes, case: :lower)

  defp to_hex_bytes32("0x" <> hex) when byte_size(hex) == 64, do: "0x" <> hex
  defp to_hex_bytes32(hex) when is_binary(hex) and byte_size(hex) == 64, do: hex

  @impl true
  def pay_and_accept_requirement(job_id, authorization)
      when is_binary(job_id) and is_binary(authorization) do
    call_data =
      ABI.encode_call(@sig_pay_and_accept, [
        {"uint256", job_id_to_uint256(job_id)},
        {"bytes", authorization}
      ])

    case send_tx(:pay_and_accept_requirement, call_data) do
      {:ok, tx_hash, _receipt} -> {:ok, tx_hash}
      {:error, _} = err -> err
    end
  end

  # -- Send pipeline --

  defp send_tx(method, call_data) do
    with {:ok, ctx} <- build_context(),
         {:ok, tx_hash, receipt} <- send_with(ctx, method, call_data) do
      {:ok, tx_hash, receipt}
    end
  end

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

  defp contract_address(%{acp_contract_address: nil}), do: {:error, :no_contract_address}
  defp contract_address(%{acp_contract_address: addr}), do: {:ok, addr}

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
    # Per the InMemory client, job ids are opaque strings. The Onchain
    # impl currently returns the tx_hash hex as the job id (see the
    # placeholder_job_id caveat in the moduledoc). When LogDecoder
    # lands and the real JobCreated event surfaces a uint256, we'll
    # parse it directly.
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
